// 
// Copyright 2020 The Matrix.org Foundation C.I.C
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

public enum MXBackgroundSyncServiceError: Error {
    case unknown
    case unknownAlgorithm
}

@objcMembers
public class MXBackgroundSyncService: NSObject {
    
    private enum Queues {
        static let processingQueue: DispatchQueue = DispatchQueue(label: "MXBackgroundSyncServiceQueue")
        static let dispatchQueue: DispatchQueue = .main
    }
    
    private enum Constants {
        static let syncRequestServerTimout: UInt = 0
        static let syncRequestClientTimout: UInt = 20 * 1000
        static let syncRequestPresence: String = "offline"
    }
    
    private let credentials: MXCredentials
    private let syncResponseStore: SyncResponseStore
    private let store: MXStore
    private let cryptoStore: MXCryptoStore
    private let olmDevice: MXOlmDevice
    private let restClient: MXRestClient
    private var pushRulesManager: MXBackgroundPushRulesManager
    
    /// Cached events. Keys are eventId's
    private var cachedEvents: [String: MXEvent] = [:]
    
    public init(withCredentials credentials: MXCredentials) {
        self.credentials = credentials
        syncResponseStore = SyncResponseFileStore()
        syncResponseStore.open(withCredentials: credentials)
        restClient = MXRestClient(credentials: credentials, unrecognizedCertificateHandler: nil)
        store = MXBackgroundSyncMemoryStore(withCredentials: credentials)
        store.open(with: credentials, onComplete: nil, failure: nil)
        if MXRealmCryptoStore.hasData(for: credentials) {
            cryptoStore = MXRealmCryptoStore(credentials: credentials)
        } else {
            cryptoStore = MXRealmCryptoStore.createStore(with: credentials)
        }
        olmDevice = MXOlmDevice(store: cryptoStore)
        pushRulesManager = MXBackgroundPushRulesManager(withRestClient: restClient)
        super.init()
    }
    
    public func event(withEventId eventId: String,
                      inRoom roomId: String,
                      completion: @escaping (MXResponse<MXEvent>) -> Void) {
        Queues.processingQueue.async {
            self._event(withEventId: eventId, inRoom: roomId, completion: completion)
        }
    }
    
    public func roomState(forRoomId roomId: String,
                          completion: @escaping (MXResponse<MXRoomState>) -> Void) {
        MXRoomState.load(from: store,
                         withRoomId: roomId,
                         matrixSession: nil) { (roomState) in
                            guard let roomState = roomState else {
                                Queues.dispatchQueue.async {
                                    completion(.failure(MXBackgroundSyncServiceError.unknown))
                                }
                                return
                            }
                            Queues.dispatchQueue.async {
                                completion(.success(roomState))
                            }
        }
    }
    
    public func isRoomMentionsOnly(_ roomId: String) -> Bool {
        return pushRulesManager.isRoomMentionsOnly(roomId)
    }
    
    public func roomSummary(forRoomId roomId: String) -> MXRoomSummary? {
        return store.summary?(ofRoom: roomId)
    }
    
    public func pushRule(matching event: MXEvent, roomState: MXRoomState) -> MXPushRule? {
        guard let currentUserId = credentials.userId else { return nil }
        let currentUser = store.user(withUserId: currentUserId)
        return pushRulesManager.pushRule(matching: event,
                                         roomState: roomState,
                                         currentUserDisplayName: currentUser?.displayname)
    }
    
    //  MARK: - Private
    
    private func _event(withEventId eventId: String,
                        inRoom roomId: String,
                        allowSync: Bool = true,
                        completion: @escaping (MXResponse<MXEvent>) -> Void) {
        /// Inline function to handle decryption failure
        func handleDecryptionFailure(withError error: Error?) {
            if allowSync {
                NSLog("[MXBackgroundSyncService] fetchEvent: Launch a background sync.")
                self.launchBackgroundSync(forEventId: eventId, roomId: roomId, completion: completion)
            } else {
                NSLog("[MXBackgroundSyncService] fetchEvent: Do not sync anymore.")
                Queues.dispatchQueue.async {
                    completion(.failure(error ?? NSError(domain: "", code: 0, userInfo: nil)))
                }
            }
        }

        /// Inline function to handle encryption for event, either from cache or from the backend
        /// - Parameter event: The event to be handled
        func handleEncryption(forEvent event: MXEvent) {
            if !event.isEncrypted {
                //  not encrypted, go on processing
                NSLog("[MXBackgroundSyncService] fetchEvent: Event not encrypted.")
                Queues.dispatchQueue.async {
                    completion(.success(event))
                }
                return
            }
            
            //  encrypted
            if event.clear != nil {
                //  already decrypted
                NSLog("[MXBackgroundSyncService] fetchEvent: Event already decrypted.")
                Queues.dispatchQueue.async {
                    completion(.success(event))
                }
                return
            }
            
            //  should decrypt it first
            if canDecryptEvent(event) {
                //  we have keys to decrypt the event
                NSLog("[MXBackgroundSyncService] fetchEvent: Event needs to be decrpyted, and we have the keys to decrypt it.")
                
                do {
                    try decryptEvent(event)
                    Queues.dispatchQueue.async {
                        completion(.success(event))
                    }
                } catch let error {
                    NSLog("[MXBackgroundSyncService] fetchEvent: Decryption failed even crypto claimed it has the keys.")
                    handleDecryptionFailure(withError: error)
                }
            } else {
                //  we don't have keys to decrypt the event
                NSLog("[MXBackgroundSyncService] fetchEvent: Event needs to be decrpyted, but we don't have the keys to decrypt it.")
                handleDecryptionFailure(withError: nil)
            }
        }
        
        //  check if we've fetched the event before
        if let cachedEvent = self.cachedEvents[eventId] {
            //  use cached event
            handleEncryption(forEvent: cachedEvent)
        } else {
            //  do not call the /event api and just check if the event exists in the store
            let event = store.event(withEventId: eventId, inRoom: roomId) ?? syncResponseStore.event(withEventId: eventId, inRoom: roomId)
            
            if let event = event {
                NSLog("[MXBackgroundSyncService] fetchEvent: We have the event in stores.")
                //  cache this event
                self.cachedEvents[eventId] = event
                
                //  handle encryption for this event
                handleEncryption(forEvent: event)
            } else if allowSync {
                NSLog("[MXBackgroundSyncService] fetchEvent: We don't have the event in stores. Launch a background sync to fetch it.")
                self.launchBackgroundSync(forEventId: eventId, roomId: roomId, completion: completion)
            } else {
                NSLog("[MXBackgroundSyncService] fetchEvent: We don't have the event in stores. Do not sync anymore.")
                Queues.dispatchQueue.async {
                    completion(.failure(NSError(domain: "", code: 0, userInfo: nil)))
                }
            }
        }
    }
    
    private func launchBackgroundSync(forEventId eventId: String,
                                      roomId: String,
                                      completion: @escaping (MXResponse<MXEvent>) -> Void) {
        guard let eventStreamToken = store.eventStreamToken else {
            return
        }
        
        restClient.sync(fromToken: eventStreamToken,
                        serverTimeout: Constants.syncRequestServerTimout,
                        clientTimeout: Constants.syncRequestClientTimout,
                        setPresence: Constants.syncRequestPresence,
                        filterId: store.syncFilterId!) { [weak self] (response) in
            switch response {
            case .success(let syncResponse):
                guard let self = self else {
                    NSLog("[MXBackgroundSyncService] launchBackgroundSync: MXSession.initialBackgroundSync returned too late successfully")
                    return
                }

                self.handleSyncResponse(syncResponse)
                
                if let event = self.syncResponseStore.event(withEventId: eventId, inRoom: roomId), !self.canDecryptEvent(event) {
                    //  we got the event but not the keys to decrypt it. continue to sync
                    Queues.processingQueue.async {
                        self.launchBackgroundSync(forEventId: eventId, roomId: roomId, completion: completion)
                    }
                } else {
                    //  do not allow to sync anymore
                    Queues.processingQueue.async {
                        self._event(withEventId: eventId, inRoom: roomId, allowSync: false, completion: completion)
                    }
                }
            case .failure(let error):
                guard let _ = self else {
                    NSLog("[MXBackgroundSyncService] launchBackgroundSync: MXSession.initialBackgroundSync returned too late with error: \(String(describing: error))")
                    return
                }
                NSLog("[MXBackgroundSyncService] launchBackgroundSync: MXSession.initialBackgroundSync returned with error: \(String(describing: error))")
                Queues.dispatchQueue.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    private func canDecryptEvent(_ event: MXEvent) -> Bool {
        if !event.isEncrypted {
            return true
        }
        
        guard let senderKey = event.content["sender_key"] as? String,
            let sessionId = event.content["session_id"] as? String else {
            return false
        }
        
        return cryptoStore.inboundGroupSession(withId: sessionId, andSenderKey: senderKey) != nil
    }
    
    private func decryptEvent(_ event: MXEvent) throws {
        guard let senderKey = event.content["sender_key"] as? String,
            let algorithm = event.content["algorithm"] as? String else {
                throw MXBackgroundSyncServiceError.unknown
        }
        
        guard let decryptorClass = MXCryptoAlgorithms.shared()?.decryptorClass(forAlgorithm: algorithm) else {
            throw MXBackgroundSyncServiceError.unknownAlgorithm
        }
        
        if decryptorClass == MXMegolmDecryption.self {
            guard let ciphertext = event.content["ciphertext"] as? String,
                let sessionId = event.content["session_id"] as? String else {
                    throw MXBackgroundSyncServiceError.unknown
            }
            
            let olmResult = try olmDevice.decryptGroupMessage(ciphertext, roomId: event.roomId, inTimeline: nil, sessionId: sessionId, senderKey: senderKey)
            
            let decryptionResult = MXEventDecryptionResult()
            decryptionResult.clearEvent = olmResult.payload
            decryptionResult.senderCurve25519Key = olmResult.senderKey
            decryptionResult.claimedEd25519Key = olmResult.keysClaimed["ed25519"] as? String
            decryptionResult.forwardingCurve25519KeyChain = olmResult.forwardingCurve25519KeyChain
            event.setClearData(decryptionResult)
        } else if decryptorClass == MXOlmDecryption.self {
            guard let ciphertextDict = event.content["ciphertext"] as? [AnyHashable: Any],
                let deviceCurve25519Key = olmDevice.deviceCurve25519Key,
                let message = ciphertextDict[deviceCurve25519Key] as? [AnyHashable: Any],
                let payloadString = decryptMessageWithOlm(message: message, theirDeviceIdentityKey: senderKey) else {
                    throw MXBackgroundSyncServiceError.unknown
            }
            guard let payloadData = payloadString.data(using: .utf8),
                let payload = try? JSONSerialization.jsonObject(with: payloadData,
                                                                  options: .init(rawValue: 0)) as? [AnyHashable: Any],
                let recipient = payload["recipient"] as? String,
                recipient == credentials.userId,
                let recipientKeys = payload["recipient_keys"] as? [AnyHashable: Any],
                let ed25519 = recipientKeys["ed25519"] as? String,
                ed25519 == olmDevice.deviceEd25519Key,
                let sender = payload["sender"] as? String,
                sender == event.sender else {
                    throw MXBackgroundSyncServiceError.unknown
            }
            if let roomId = event.roomId {
                guard payload["room_id"] as? String == roomId else {
                    throw MXBackgroundSyncServiceError.unknown
                }
            }
            
            let claimedKeys = payload["keys"] as? [AnyHashable: Any]
            let decryptionResult = MXEventDecryptionResult()
            decryptionResult.clearEvent = payload
            decryptionResult.senderCurve25519Key = senderKey
            decryptionResult.claimedEd25519Key = claimedKeys?["ed25519"] as? String
            event.setClearData(decryptionResult)
        } else {
            throw MXBackgroundSyncServiceError.unknownAlgorithm
        }
    }
    
    private func decryptMessageWithOlm(message: [AnyHashable: Any], theirDeviceIdentityKey: String) -> String? {
        let sessionIds = olmDevice.sessionIds(forDevice: theirDeviceIdentityKey)
        let messageBody = message["body"] as? String
        let messageType = message["type"] as? UInt ?? 0
        
        for sessionId in sessionIds ?? [] {
            if let payload = olmDevice.decryptMessage(messageBody,
                                                      withType: messageType,
                                                      sessionId: sessionId,
                                                      theirDeviceIdentityKey: theirDeviceIdentityKey) {
                return payload
            } else {
                let foundSession = olmDevice.matchesSession(theirDeviceIdentityKey,
                                                            sessionId: sessionId,
                                                            messageType: messageType,
                                                            ciphertext: messageBody)
                if foundSession {
                    return nil
                }
            }
        }
        
        if messageType != 0 {
            return nil
        }
        
        var payload: NSString?
        guard let _ = olmDevice.createInboundSession(theirDeviceIdentityKey,
                                                     messageType: messageType,
                                                     cipherText: messageBody,
                                                     payload: &payload) else {
                                                        return nil
        }
        return payload as String?
    }
    
    private func handleSyncResponse(_ syncResponse: MXSyncResponse) {
        self.pushRulesManager.handleAccountData(syncResponse.accountData)
        self.syncResponseStore.update(with: syncResponse)
        
        for event in syncResponse.toDevice?.events ?? [] {
            handleToDeviceEvent(event)
        }
        
        //  update event stream token
        self.store.eventStreamToken = syncResponse.nextBatch
    }
    
    private func handleToDeviceEvent(_ event: MXEvent) {
        if event.isEncrypted {
            do {
                try decryptEvent(event)
            } catch let error {
                NSLog("[MXBackgroundSyncService] handleToDeviceEvent: Could not decrypt to-device event: \(error)")
                return
            }
        }
        
        guard let roomId = event.content["room_id"] as? String,
            let sessionId = event.content["session_id"] as? String,
            let sessionKey = event.content["session_key"] as? String,
            var senderKey = event.senderKey else {
            return
        }
        
        var forwardingKeyChain: [String] = []
        var exportFormat: Bool = false
        var keysClaimed: [String: String] = [:]
        
        switch event.eventType {
        case .roomKey:
            keysClaimed = event.keysClaimed as! [String: String]
            break
        case .roomForwardedKey:
            exportFormat = true
            
            if let array = event.content["forwarding_curve25519_key_chain"] as? [String] {
                forwardingKeyChain = array
            }
            forwardingKeyChain.append(senderKey)
            
            if let senderKeyInContent = event.content["sender_key"] as? String {
                senderKey = senderKeyInContent
            } else {
                return
            }
            
            guard let ed25519Key = event.content["sender_claimed_ed25519_key"] as? String else {
                return
            }
            
            keysClaimed = [
                "ed25519": ed25519Key
            ]
            break
        default:
            return
        }
        
        olmDevice.addInboundGroupSession(sessionId,
                                         sessionKey: sessionKey,
                                         roomId: roomId,
                                         senderKey: senderKey,
                                         forwardingCurve25519KeyChain: forwardingKeyChain,
                                         keysClaimed: keysClaimed,
                                         exportFormat: exportFormat)
    }
    
}