//
//  Utils.swift
//  pass
//
//  Created by Mingshen Sun on 8/2/2017.
//  Copyright © 2017 Bob Sun. All rights reserved.
//

import Foundation
import SwiftyUserDefaults
import KeychainAccess
import UIKit

class Utils {
    static func removeFileIfExists(atPath path: String) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: path) {
                try fm.removeItem(atPath: path)
            }
        } catch {
            print(error)
        }
    }
    static func removeFileIfExists(at url: URL) {
        removeFileIfExists(atPath: url.path)
    }
    
    static func getLastUpdatedTimeString() -> String {
        var lastUpdatedTimeString = ""
        if let lastUpdatedTime = Defaults[.lastUpdatedTime] {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lastUpdatedTimeString = formatter.string(from: lastUpdatedTime)
        }
        return lastUpdatedTimeString
    }
    
    static func generatePassword(length: Int) -> String{
        switch Defaults[.passwordGenerationMethod] {
        case "Random":
            return randomString(length: length)
        case "Keychain":
            return Keychain.generatePassword()
        default:
            return randomString(length: length)
        }
    }
    
    static func randomString(length: Int) -> String {
        
        let letters : NSString = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let len = UInt32(letters.length)
        
        var randomString = ""
        
        for _ in 0 ..< length {
            let rand = arc4random_uniform(len)
            var nextChar = letters.character(at: Int(rand))
            randomString += NSString(characters: &nextChar, length: 1) as String
        }
        
        return randomString
    }
    
    static func alert(title: String, message: String, controller: UIViewController, completion: (() -> Void)?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: UIAlertControllerStyle.alert)
        alert.addAction(UIAlertAction(title: "OK", style: UIAlertActionStyle.default, handler: nil))
        controller.present(alert, animated: true, completion: completion)

    }
    
    static func removePGPKeys() {
        removeFileIfExists(atPath: Globals.pgpPublicKeyPath)
        removeFileIfExists(atPath: Globals.pgpPrivateKeyPath)
        Defaults.remove(.pgpKeySource)
        Defaults.remove(.pgpPublicKeyArmor)
        Defaults.remove(.pgpPrivateKeyArmor)
        Defaults.remove(.pgpPrivateKeyURL)
        Defaults.remove(.pgpPublicKeyURL)
        Defaults.remove(.pgpKeyID)
        Utils.removeKeychain(name: ".pgpKeyPassphrase")
    }
    
    static func getPasswordFromKeychain(name: String) -> String? {
        let keychain = Keychain(service: "me.mssun.passforios")
        do {
            return try keychain.getString(name)
        } catch {
            print(error)
        }
        return nil
    }
    
    static func addPasswordToKeychain(name: String, password: String?) {
        let keychain = Keychain(service: "me.mssun.passforios")
        keychain[name] = password
    }
    static func removeKeychain(name: String) {
        let keychain = Keychain(service: "me.mssun.passforios")
        do {
            try keychain.remove(name)
        } catch {
            print(error)
        }
    }
    static func removeAllKeychain() {
        let keychain = Keychain(service: "me.mssun.passforios")
        do {
            try keychain.removeAll()
        } catch {
            print(error)
        }
    }
    static func copyToPasteboard(textToCopy: String?, expirationTime: Double = 45) {
        guard textToCopy != nil else {
            return
        }
        UIPasteboard.general.string = textToCopy
        DispatchQueue.global(qos: .background).asyncAfter(deadline: DispatchTime.now() + expirationTime) {
            let pasteboardString: String? = UIPasteboard.general.string
            if textToCopy == pasteboardString {
                UIPasteboard.general.string = ""
            }
        }
    }
    static func attributedPassword(plainPassword: String) -> NSAttributedString{
        let attributedPassword = NSMutableAttributedString.init(string: plainPassword)
        // draw all digits in the password into red
        // draw all punctuation characters in the password into blue
        for (index, element) in plainPassword.unicodeScalars.enumerated() {
            if NSCharacterSet.decimalDigits.contains(element) {
                attributedPassword.addAttribute(NSForegroundColorAttributeName, value: Globals.red, range: NSRange(location: index, length: 1))
            } else if NSCharacterSet.punctuationCharacters.contains(element) {
                attributedPassword.addAttribute(NSForegroundColorAttributeName, value: Globals.blue, range: NSRange(location: index, length: 1))
            }
        }
        return attributedPassword
    }
}

// https://gist.github.com/NikolaiRuhe/eeb135d20c84a7097516
extension FileManager {
    
    /// This method calculates the accumulated size of a directory on the volume in bytes.
    ///
    /// As there's no simple way to get this information from the file system it has to crawl the entire hierarchy,
    /// accumulating the overall sum on the way. The resulting value is roughly equivalent with the amount of bytes
    /// that would become available on the volume if the directory would be deleted.
    ///
    /// - note: There are a couple of oddities that are not taken into account (like symbolic links, meta data of
    /// directories, hard links, ...).
    func allocatedSizeOfDirectoryAtURL(directoryURL : URL) throws -> UInt64 {
        
        // We'll sum up content size here:
        var accumulatedSize = UInt64(0)
        
        // prefetching some properties during traversal will speed up things a bit.
        let prefetchedProperties = [
            URLResourceKey.isRegularFileKey,
            URLResourceKey.fileAllocatedSizeKey,
            URLResourceKey.totalFileAllocatedSizeKey,
            ]
        
        // The error handler simply signals errors to outside code.
        var errorDidOccur: Error?
        let errorHandler: (URL, Error) -> Bool = { _, error in
            errorDidOccur = error
            return false
        }
        
        
        // We have to enumerate all directory contents, including subdirectories.
        let enumerator = self.enumerator(at: directoryURL,
                                              includingPropertiesForKeys: prefetchedProperties,
                                              options: FileManager.DirectoryEnumerationOptions(),
                                              errorHandler: errorHandler)
        precondition(enumerator != nil)
        
        // Start the traversal:
        for item in enumerator! {
            let contentItemURL = item as! NSURL
            
            // Bail out on errors from the errorHandler.
            if let error = errorDidOccur { throw error }
            
            let resourceValueForKey: (URLResourceKey) throws -> NSNumber? = { key in
                var value: AnyObject?
                try contentItemURL.getResourceValue(&value, forKey: key)
                return value as? NSNumber
            }
            
            // Get the type of this item, making sure we only sum up sizes of regular files.
            guard let isRegularFile = try resourceValueForKey(URLResourceKey.isRegularFileKey) else {
                preconditionFailure()
            }
            
            guard isRegularFile.boolValue else {
                continue
            }
            
            // To get the file's size we first try the most comprehensive value in terms of what the file may use on disk.
            // This includes metadata, compression (on file system level) and block size.
            var fileSize = try resourceValueForKey(URLResourceKey.totalFileAllocatedSizeKey)
            
            // In case the value is unavailable we use the fallback value (excluding meta data and compression)
            // This value should always be available.
            fileSize = try fileSize ?? resourceValueForKey(URLResourceKey.fileAllocatedSizeKey)
            
            guard let size = fileSize else {
                preconditionFailure("huh? NSURLFileAllocatedSizeKey should always return a value")
            }
            
            // We're good, add up the value.
            accumulatedSize += size.uint64Value
        }
        
        // Bail out on errors from the errorHandler.
        if let error = errorDidOccur { throw error }
        
        // We finally got it.
        return accumulatedSize
    }
}
