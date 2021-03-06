//
//  MessageHandlingOperation.swift
//
//  Created by Andrey K. on 20/04/16.
//
//

import UIKit
import CoreData

func == (lhs: MMMessageMeta, rhs: MMMessageMeta) -> Bool {
	return lhs.hashValue == rhs.hashValue
}

struct MMMessageMeta : MMMessageMetadata {
	let isSilent: Bool
	let messageId: String
	
	var hashValue: Int {
		return messageId.hash
	}
	
	init(message: MessageManagedObject) {
		self.messageId = message.messageId
		self.isSilent = message.isSilent
	}
	
	init(message: MTMessage) {
		self.messageId = message.messageId
		self.isSilent = message.isSilent
	}
	
	init(message: MOMessage) {
		self.messageId = message.messageId
		self.isSilent = false
	}
}

final class MessageHandlingOperation: Operation {
	let context: NSManagedObjectContext
	let finishBlock: ((NSError?, Set<MTMessage>?) -> Void)?
	let messagesToHandle: [MTMessage]
	let isNotificationTapped: Bool
	let mmContext: MobileMessaging
	
	init(messagesToHandle: [MTMessage], context: NSManagedObjectContext, isNotificationTapped: Bool = false, mmContext: MobileMessaging, finishBlock: ((NSError?, Set<MTMessage>?) -> Void)? = nil) {
		self.messagesToHandle = messagesToHandle //can be either native APNS or custom Server layout
		self.context = context
		self.finishBlock = finishBlock
		self.isNotificationTapped = isNotificationTapped
		self.mmContext = mmContext
		super.init()
		
		self.userInitiated = true
	}
	
	override func execute() {
		MMLogDebug("[Message handling] Starting message handling operation...")
		context.reset()
		guard !newMessages.isEmpty else
		{
			MMLogDebug("[Message handling] There is no new messages to handle.")
			handleExistentMessageTappedIfNeeded()
			finish()
			return
		}
		
		MMLogDebug("[Message handling] There are \(newMessages.count) new messages to handle.")
		
		context.performAndWait {
			self.newMessages.forEach { newMessage in
				var messageWasPopulatedBySubservice = false
				var newDBMessage = MessageManagedObject.MM_createEntityInContext(context: self.context)
				self.mmContext.performForEachSubservice { subservice in
					messageWasPopulatedBySubservice = subservice.populateNewPersistedMessage(&newDBMessage, originalMessage: newMessage) || messageWasPopulatedBySubservice
				}
				if !messageWasPopulatedBySubservice {
					MMLogDebug("[Message handling] message \(newMessage.messageId) was not populated by any subservice")
					self.context.delete(newDBMessage)
					self.newMessages.remove(newMessage)
				}
			}
			self.context.MM_saveToPersistentStoreAndWait()
		}
		
		let regularMessages: [MTMessage] = newMessages.filter { !$0.isGeoSignalingMessage } //workaround. The message handling must not know about geo messages. Redesign needed.
		populateMessageStorageWithNewMessages(regularMessages) {
			self.notifyAboutNewMessages(regularMessages) {
				self.handleNotificationTappedIfNeeded(regularMessages)
				self.finish()
			}
		}
	}
	
	private func populateMessageStorageWithNewMessages(_ messages: [MTMessage], completion: @escaping () -> Void) {
		guard !messages.isEmpty else
		{
			completion()
			return
		}
		let storages = mmContext.messageStorages.values
		MMLogDebug("[Message handling] inserting messages in message storage: \(messages)")
		storages.forEachAsync({ (storage, finishBlock) in
			storage.insert(incoming: messages, completion: finishBlock)
		}, completion: completion)
	}
	
	private func notifyAboutNewMessages(_ messages: [MTMessage], completion: (() -> Void)? = nil) {
		guard !messages.isEmpty else
		{
			completion?()
			return
		}
		
		let group = DispatchGroup()
		DispatchQueue.main.async(group: group, execute: DispatchWorkItem(block: {
			messages.forEach { message in
				MMLogDebug("[Message handling] calling back for didReceiveNewMessage \(message.messageId)")
                
                self.presentLocalNotificationIfNeeded(with: message)
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: MMNotificationMessageReceived), object: self, userInfo: [MMNotificationKeyMessage: message])

				MobileMessaging.messageHandlingDelegate?.didReceiveNewMessage?(message: message)
                if MobileMessaging.application.isInForegroundState {
                    MobileMessaging.messageHandlingDelegate?.didReceiveNewMessageInForeground?(message: message)
                }
			}
		}))
		group.wait()
		completion?()
	}
	
//MARK: - Notification tap handling
    private func presentLocalNotificationIfNeeded(with message: MTMessage) {
        guard (!message.isSilent || message.isGeoSignalingMessage) && (message.deliveryMethod == .pull || message.deliveryMethod == .generatedLocally) else { return }
        LocalNotifications.presentLocalNotification(with: message)
    }
    
	private func handleNotificationTappedIfNeeded(_ messages: [MTMessage]) {
		guard let newMessage = messages.first else { return }
		handleNotificationTappedIfNeeded(with: newMessage)
	}

	private func handleExistentMessageTappedIfNeeded() {
		guard let existentMessage = intersectingMessages.first else { return }
		handleNotificationTappedIfNeeded(with: existentMessage)
	}
	
	private func handleNotificationTappedIfNeeded(with message: MTMessage) {
        guard isNotificationTapped, message.deliveryMethod == .push else { return }
        
        message.appliedAction = NotificationAction.defaultAction
	}
	
//MARK: - Lazy message collections
	private lazy var storedMessageMetasSet: Set<MMMessageMeta> = {
		var result: Set<MMMessageMeta> = Set()
		//TODO: optimization needed, it may be too many of db messages
		self.context.performAndWait {
			if let storedMessages = MessageManagedObject.MM_findAllInContext(self.context) {
				result = Set(storedMessages.map(MMMessageMeta.init))
			}
		}
		return result
	}()
	
	private lazy var newMessages: Set<MTMessage> = {
		guard !self.messagesToHandle.isEmpty else { return Set<MTMessage>() }
		let messagesToHandleMetasSet = Set(self.messagesToHandle.map(MMMessageMeta.init))
		return Set(messagesToHandleMetasSet.subtracting(self.storedMessageMetasSet).compactMap { return self.mtMessage(from: $0) })
	}()
	
	private lazy var intersectingMessages: [MTMessage] = {
		guard !self.messagesToHandle.isEmpty else { return [MTMessage]() }
		let messagesToHandleMetasSet = Set(self.messagesToHandle.map(MMMessageMeta.init))
		return messagesToHandleMetasSet.intersection(self.storedMessageMetasSet).compactMap { return self.mtMessage(from: $0) }
	}()
	
//MARK: - Lazy message collections
	private func mtMessage(from meta: MMMessageMeta) -> MTMessage? {
		return messagesToHandle.first() { msg -> Bool in
			return msg.messageId == meta.messageId
		}
	}
	
//MARK: -
	override func finished(_ errors: [NSError]) {
		MMLogDebug("[Message handling] Message handling finished with errors: \(errors)")
		self.finishBlock?(errors.first, newMessages)
	}
}
