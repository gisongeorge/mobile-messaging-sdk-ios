//
//  ViewController.swift
//  MobileMessaging
//
//  Created by Andrey K. on 03/29/2016.
//  Copyright (c) 2016 Andrey K.. All rights reserved.
//

import UIKit
import MobileMessaging
import Freddy

let kMessageCellId = "kMessageCellId"
let kMessageDetailsSegueId = "kMessageDetailsSegueId"
let kInformationSegueId = "kInformationSegueId"
let kSettingsSegueId = "kSettingsSegueId"
let kMessagesKey = "kMessagesKey"
let kMessageDidChangeSeenNotification = "kMessageDidChangeSeenNotification"

class Message : NSObject, NSCoding {
    var text: String
    var messageId: String
    dynamic var delivered: Bool = false
	var seen : Bool = false {
		didSet {
			NSNotificationCenter.defaultCenter().postNotificationName(kMessageDidChangeSeenNotification, object: self, userInfo: nil)
		}
	}
	
    required init(text: String, messageId: String){
        self.text = text
        self.messageId = messageId
        super.init()
    }
    
    //MARK: NSCoding
    required init(coder aDecoder: NSCoder) {
        text = aDecoder.decodeObjectForKey("text") as! String
        messageId = aDecoder.decodeObjectForKey("messageId") as! String
        delivered = aDecoder.decodeObjectForKey("delivered") as! Bool
		seen = aDecoder.decodeObjectForKey("seen") as! Bool
    }
    
    func encodeWithCoder(aCoder: NSCoder) {
        aCoder.encodeObject(text, forKey: "text")
        aCoder.encodeObject(messageId, forKey: "messageId")
        aCoder.encodeObject(delivered, forKey: "delivered")
		aCoder.encodeObject(seen, forKey: "seen")
    }
    
    //MARK: Util
    class func prepare(rawMessage: [NSObject : AnyObject]) -> Message? {
        guard let aps = rawMessage["aps"] as? [NSObject : AnyObject],
            let messageId = rawMessage["messageId"] as? String else {
                return nil
        }
        
        var text = String()
        if let alert = aps["alert"] as? String {
            text = alert
        } else if let alert = aps["alert"] as? [NSObject : AnyObject],
            let body = alert["body"] as? String {
                text = body
        } else {
            return nil
        }
        
        return Message(text: text, messageId: messageId)
    }
}

class ListViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    
    @IBOutlet weak var tableView: UITableView!
    
	@IBAction func trashInbox(sender: AnyObject) {
		messages.removeAll()
		NSUserDefaults.standardUserDefaults().removeObjectForKey(kMessagesKey)
		updateUI()
	}
	
    var messages:[Message] = [Message]()
    let cellFont = UIFont.systemFontOfSize(15.0)
	let unreadCellFont = UIFont.boldSystemFontOfSize(15.0)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        startObservingNotifications()
        unarchiveMessages()
        tableView.registerClass(UITableViewCell.self, forCellReuseIdentifier: kMessageCellId)
		tableView.estimatedRowHeight = 44
		tableView.rowHeight = UITableViewAutomaticDimension;
	
        updateUI()
		
//		for i in 0..<10 {
//			MobileMessaging.didReceiveRemoteNotification(["messageId": "m\(i)", "aps": ["alert": "alert\(i)"]], fetchCompletionHandler: nil)
//		}
		
//		for i in 0..<10 {
//			let error = NSError(domain: "foo", code: 123, userInfo: [NSLocalizedDescriptionKey: "shit happens-\(i)"])
//			NSNotificationCenter.defaultCenter().postNotificationName(MMEventNotifications.kAPIError, object: self, userInfo: [MMEventNotifications.kAPIErrorUserInfoKey: error])
//		}
	}
    
    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }
    
    
    //MARK: Handle MobileMessaging notifications
    func handleNewMessageReceivedNotification(notification: NSNotification) {
        guard let userInfo = notification.userInfo,
            let messageUserInfo = userInfo[MMEventNotifications.kMessageUserInfoKey] as? [NSObject : AnyObject],
            let message = Message.prepare(messageUserInfo) else {
                return
        }
        
        saveMessage(message)
    }
    
    func handleDeliveryReportSentNotification(notification: NSNotification) {
        guard let userInfo = notification.userInfo,
            let messageUserInfo = userInfo[MMEventNotifications.kMessageIDsUserInfoKey] as? [String] else {
                return
        }
        
        for message in messages {
            if messageUserInfo.contains(message.messageId) {
                message.delivered = true
            }
        }
    }
	
	func handleMessageDidChangeSeenNotification(notification: NSNotification) {
		archiveMessages()
		updateUI()
	}

    
    //MARK: UITableViewDataSource
    func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return messages.count
    }

    func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellWithIdentifier(kMessageCellId, forIndexPath: indexPath)
		let message = messages[indexPath.row]
        cell.textLabel?.numberOfLines = 5
		cell.textLabel?.font = message.seen ? cellFont : unreadCellFont
        cell.textLabel?.text = message.text
		cell.accessoryType = .DisclosureIndicator
        return cell
    }
	
	func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
		performSegueWithIdentifier(kMessageDetailsSegueId, sender: indexPath)
	}
    
    //MARK: Segues
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject?) {
        if segue.identifier == kMessageDetailsSegueId,
            let vc = segue.destinationViewController as? MessageDetailsViewController,
            let indexPath = sender as? NSIndexPath {
                vc.message = messages[indexPath.row]
        }
    }

    //MARK: Utils
    func updateUIWithInsertMessage() {
        tableView.insertRowsAtIndexPaths([NSIndexPath(forItem: 0, inSection: 0)], withRowAnimation: .Right)
        tableView.selectRowAtIndexPath(NSIndexPath(forItem: 0, inSection: 0), animated: true, scrollPosition: .Middle)
    }
    
    func updateUI() {
        tableView.reloadData()
    }
    
	func startObservingNotifications() {
		NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(ListViewController.handleNewMessageReceivedNotification(_:)), name: MMEventNotifications.kMessageReceived, object: nil)
		NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(ListViewController.handleDeliveryReportSentNotification(_:)), name: MMEventNotifications.kDeliveryReportSent, object: nil)
		NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(ListViewController.handleMessageDidChangeSeenNotification(_:)), name: kMessageDidChangeSeenNotification, object: nil)
	}
	
    func saveMessage(message: Message) {
        messages.insert(message, atIndex: 0)
        archiveMessages()
        updateUIWithInsertMessage()
    }
	
	func archiveMessages() {
		let data: NSData = NSKeyedArchiver.archivedDataWithRootObject(messages)
		NSUserDefaults.standardUserDefaults().setObject(data, forKey: kMessagesKey)
	}
	
    func unarchiveMessages() {
        if let messagesData = NSUserDefaults.standardUserDefaults().objectForKey(kMessagesKey) as? NSData,
            let messages = NSKeyedUnarchiver.unarchiveObjectWithData(messagesData) as? [Message] {
                self.messages.appendContentsOf(messages)
        }
    }
}
