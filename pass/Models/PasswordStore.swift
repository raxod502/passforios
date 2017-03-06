//
//  PasswordStore.swift
//  pass
//
//  Created by Mingshen Sun on 19/1/2017.
//  Copyright © 2017 Bob Sun. All rights reserved.
//

import Foundation
import CoreData
import UIKit
import SwiftyUserDefaults
import ObjectiveGit
import SVProgressHUD

struct GitCredential {
    
    enum Credential {
        case http(userName: String, password: String)
        case ssh(userName: String, password: String, publicKeyFile: URL, privateKeyFile: URL, passwordNotSetCallback: (() -> String)? )
    }
    
    var credential: Credential

    func credentialProvider() throws -> GTCredentialProvider {
        return GTCredentialProvider { (_, _, _) -> (GTCredential?) in
            var credential: GTCredential? = nil
            switch self.credential {
            case let .http(userName, password):
                print(Defaults[.gitRepositoryPasswordAttempts])
                var newPassword: String = password
                if Defaults[.gitRepositoryPasswordAttempts] != 0 {
                    let sem = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async {
                        SVProgressHUD.dismiss()
                        if var topController = UIApplication.shared.keyWindow?.rootViewController {
                            while let presentedViewController = topController.presentedViewController {
                                topController = presentedViewController
                            }
                            let alert = UIAlertController(title: "Password", message: "Please fill in the password of your Git account.", preferredStyle: UIAlertControllerStyle.alert)
                            alert.addAction(UIAlertAction(title: "OK", style: UIAlertActionStyle.default, handler: {_ in
                                newPassword = alert.textFields!.first!.text!
                                PasswordStore.shared.gitRepositoryPassword = newPassword
                                sem.signal()
                            }))
                            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                                Defaults[.gitRepositoryPasswordAttempts] = -1
                                sem.signal()
                            })
                            alert.addTextField(configurationHandler: {(textField: UITextField!) in
                                textField.text = PasswordStore.shared.gitRepositoryPassword
                                textField.isSecureTextEntry = true
                            })
                                topController.present(alert, animated: true, completion: nil)
                            }
                    }
                    let _ = sem.wait(timeout: DispatchTime.distantFuture)
                }
                if Defaults[.gitRepositoryPasswordAttempts] == -1 {
                    Defaults[.gitRepositoryPasswordAttempts] = 0
                    return nil
                }
                Defaults[.gitRepositoryPasswordAttempts] += 1
                PasswordStore.shared.gitRepositoryPassword = newPassword
                credential = try? GTCredential(userName: userName, password: newPassword)
            case let .ssh(userName, password, publicKeyFile, privateKeyFile, passwordNotSetCallback):

                var newPassword:String? = password

                // Check if the private key is encrypted
                let encrypted = try? String(contentsOf: privateKeyFile).contains("ENCRYPTED")

                // Request password if not already set
                if encrypted! && password == "" {
                    newPassword = passwordNotSetCallback!()
                }

                // Save password for the future
                Utils.addPasswordToKeychain(name: "gitRepositorySSHPrivateKeyPassphrase", password: newPassword!)

                // nil is expected in case of empty password
                if newPassword == "" {
                    newPassword = nil
                }


                credential = try? GTCredential(userName: userName, publicKeyURL: publicKeyFile, privateKeyURL: privateKeyFile, passphrase: newPassword)
            }
            return credential
        }
    }
}

class PasswordStore {
    static let shared = PasswordStore()
    
    let storeURL = URL(fileURLWithPath: "\(Globals.repositoryPath)")
    let tempStoreURL = URL(fileURLWithPath: "\(Globals.repositoryPath)-temp")
    var storeRepository: GTRepository?
    var gitCredential: GitCredential?
    
    let pgp: ObjectivePGP = ObjectivePGP()
    
    var pgpKeyPassphrase: String? {
        set {
            Utils.addPasswordToKeychain(name: "pgpKeyPassphrase", password: newValue)
        }
        get {
            return Utils.getPasswordFromKeychain(name: "pgpKeyPassphrase")
        }
    }
    var gitRepositoryPassword: String? {
        set {
            Utils.addPasswordToKeychain(name: "gitRepositoryPassword", password: newValue)
        }
        get {
            return Utils.getPasswordFromKeychain(name: "gitRepositoryPassword")
        }
    }
    
    let context = (UIApplication.shared.delegate as! AppDelegate).persistentContainer.viewContext

    
    private init() {
        do {
            if FileManager.default.fileExists(atPath: storeURL.path) {
                try storeRepository = GTRepository.init(url: storeURL)
            }
        } catch {
            print(error)
        }
        if Defaults[.pgpKeyID] != nil {
            pgp.importKeys(fromFile: Globals.pgpPublicKeyPath, allowDuplicates: false)
            pgp.importKeys(fromFile: Globals.pgpPrivateKeyPath, allowDuplicates: false)

        }
        if Defaults[.gitRepositoryAuthenticationMethod] == "Password" {
            gitCredential = GitCredential(credential: GitCredential.Credential.http(userName: Defaults[.gitRepositoryUsername]!, password: Utils.getPasswordFromKeychain(name: "gitRepositoryPassword") ?? ""))
        } else if Defaults[.gitRepositoryAuthenticationMethod] == "SSH Key"{
            gitCredential = GitCredential(
                credential: GitCredential.Credential.ssh(
                    userName: Defaults[.gitRepositoryUsername]!,
                    password: Utils.getPasswordFromKeychain(name: "gitRepositorySSHPrivateKeyPassphrase") ?? "",
                    publicKeyFile: Globals.sshPublicKeyURL,
                    privateKeyFile: Globals.sshPrivateKeyURL,
                    passwordNotSetCallback: nil
                )
            )
        } else {
            gitCredential = nil
        }
        
    }
    
    func initPGP(pgpPublicKeyLocalPath: String, pgpPrivateKeyLocalPath: String) throws {
        let pgpPublicKeyData = NSData(contentsOfFile: pgpPublicKeyLocalPath)! as Data
        if pgpPublicKeyData.count == 0 {
            throw NSError(domain: "me.mssun.pass.error", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot import public key."])
        }
        pgp.importKeys(from: pgpPublicKeyData, allowDuplicates: false)
        if pgp.getKeysOf(.public).count == 0 {
            throw NSError(domain: "me.mssun.pass.error", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot import public key."])
        }
        let pgpPrivateKeyData = NSData(contentsOfFile: pgpPrivateKeyLocalPath)! as Data
        if pgpPrivateKeyData.count == 0 {
            throw NSError(domain: "me.mssun.pass.error", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot import public key."])
        }
        pgp.importKeys(from: pgpPrivateKeyData, allowDuplicates: false)
        if pgp.getKeysOf(.secret).count == 0 {
            throw NSError(domain: "me.mssun.pass.error", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot import seceret key."])
        }
        let key: PGPKey = getPgpPrivateKey()
        Defaults[.pgpKeyID] = key.keyID!.shortKeyString
        if let gpgUser = key.users[0] as? PGPUser {
            Defaults[.pgpKeyUserID] = gpgUser.userID
        }
    }

    func getPgpPrivateKey() -> PGPKey {
        return pgp.getKeysOf(.secret)[0]
    }
    
    func repositoryExisted() -> Bool {
        let fm = FileManager()
        return fm.fileExists(atPath: Globals.repositoryPath)
    }
    
    func passwordExisted(password: Password) -> Bool {
        print(password.name)
        let passwordEntityFetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "PasswordEntity")
        do {
            passwordEntityFetchRequest.predicate = NSPredicate(format: "name = %@", password.name)
            let count = try context.count(for: passwordEntityFetchRequest)
            if count > 0 {
                return true
            } else {
                return false
            }
        } catch {
            fatalError("Failed to fetch password entities: \(error)")
        }
        return true
    }
    
    func initPGP(pgpPublicKeyURL: URL, pgpPublicKeyLocalPath: String, pgpPrivateKeyURL: URL, pgpPrivateKeyLocalPath: String) throws {
        let pgpPublicData = try Data(contentsOf: pgpPublicKeyURL)
        try pgpPublicData.write(to: URL(fileURLWithPath: pgpPublicKeyLocalPath), options: .atomic)
        let pgpPrivateData = try Data(contentsOf: pgpPrivateKeyURL)
        try pgpPrivateData.write(to: URL(fileURLWithPath: pgpPrivateKeyLocalPath), options: .atomic)
        try initPGP(pgpPublicKeyLocalPath: pgpPublicKeyLocalPath, pgpPrivateKeyLocalPath: pgpPrivateKeyLocalPath)
    }
    
    func initPGP(pgpPublicKeyArmor: String, pgpPublicKeyLocalPath: String, pgpPrivateKeyArmor: String, pgpPrivateKeyLocalPath: String) throws {
        try pgpPublicKeyArmor.write(toFile: pgpPublicKeyLocalPath, atomically: true, encoding: .ascii)
        try pgpPrivateKeyArmor.write(toFile: pgpPrivateKeyLocalPath, atomically: true, encoding: .ascii)
        try initPGP(pgpPublicKeyLocalPath: pgpPublicKeyLocalPath, pgpPrivateKeyLocalPath: pgpPrivateKeyLocalPath)
    }
    
    func cloneRepository(remoteRepoURL: URL,
                         credential: GitCredential,
                         transferProgressBlock: @escaping (UnsafePointer<git_transfer_progress>, UnsafeMutablePointer<ObjCBool>) -> Void,
                         checkoutProgressBlock: @escaping (String?, UInt, UInt) -> Void) throws {
        Utils.removeFileIfExists(at: storeURL)
        Utils.removeFileIfExists(at: tempStoreURL)
        
        let credentialProvider = try credential.credentialProvider()
        let options: [String: Any] = [
            GTRepositoryCloneOptionsCredentialProvider: credentialProvider,
        ]
        storeRepository = try GTRepository.clone(from: remoteRepoURL, toWorkingDirectory: tempStoreURL, options: options, transferProgressBlock:transferProgressBlock)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: storeURL.path) {
                try fm.removeItem(at: storeURL)
            }
            try fm.copyItem(at: tempStoreURL, to: storeURL)
            try fm.removeItem(at: tempStoreURL)
        } catch {
            print(error)
        }
        storeRepository = try GTRepository(url: storeURL)
        gitCredential = credential
    }
    
    func pullRepository(transferProgressBlock: @escaping (UnsafePointer<git_transfer_progress>, UnsafeMutablePointer<ObjCBool>) -> Void) throws {
        if gitCredential == nil {
            throw NSError(domain: "me.mssun.pass.error", code: 1, userInfo: [NSLocalizedDescriptionKey: "Git Repository is not set."])
        }
        let credentialProvider = try gitCredential!.credentialProvider()
        let options: [String: Any] = [
            GTRepositoryRemoteOptionsCredentialProvider: credentialProvider
        ]
        let remote = try GTRemote(name: "origin", in: storeRepository!)
        try storeRepository?.pull((storeRepository?.currentBranch())!, from: remote, withOptions: options, progress: transferProgressBlock)
    }
    
    
    
    func updatePasswordEntityCoreData() {
        deleteCoreData(entityName: "PasswordEntity")
        let fm = FileManager.default
        do {
            var q = try fm.contentsOfDirectory(atPath: self.storeURL.path).filter{
                !$0.hasPrefix(".")
            }.map { (filename) -> PasswordEntity in
                let passwordEntity = NSEntityDescription.insertNewObject(forEntityName: "PasswordEntity", into: context) as! PasswordEntity
                if filename.hasSuffix(".gpg") {
                    passwordEntity.name = filename.substring(to: filename.index(filename.endIndex, offsetBy: -4))
                } else {
                    passwordEntity.name = filename
                }
                passwordEntity.path = filename
                passwordEntity.parent = nil
                return passwordEntity
            }
            while q.count > 0 {
                let e = q.first!
                q.remove(at: 0)
                guard !e.name!.hasPrefix(".") else {
                    continue
                }
                var isDirectory: ObjCBool = false
                let filePath = storeURL.appendingPathComponent(e.path!).path
                if fm.fileExists(atPath: filePath, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        e.isDir = true
                        let files = try fm.contentsOfDirectory(atPath: filePath).map { (filename) -> PasswordEntity in
                            let passwordEntity = NSEntityDescription.insertNewObject(forEntityName: "PasswordEntity", into: context) as! PasswordEntity
                            if filename.hasSuffix(".gpg") {
                                passwordEntity.name = filename.substring(to: filename.index(filename.endIndex, offsetBy: -4))
                            } else {
                                passwordEntity.name = filename
                            }
                            passwordEntity.path = "\(e.path!)/\(filename)"
                            passwordEntity.parent = e
                            return passwordEntity
                        }
                        q += files
                    } else {
                        e.isDir = false
                    }
                }
            }
        } catch {
            print(error)
        }
        do {
            try context.save()
        } catch {
            print("Error with save: \(error)")
        }
    }
    
    func getRecentCommits(count: Int) -> [GTCommit] {
        var commits = [GTCommit]()
        do {
            let enumerator = try GTEnumerator(repository: storeRepository!)
            try enumerator.pushSHA(storeRepository!.headReference().targetOID.sha!)
            for _ in 0 ..< count {
                let commit = try enumerator.nextObject(withSuccess: nil)
                commits.append(commit)
            }
        } catch {
            print(error)
            return commits
        }
        return commits
    }
    
    func fetchPasswordEntityCoreData(parent: PasswordEntity?) -> [PasswordEntity] {
        let passwordEntityFetch = NSFetchRequest<NSFetchRequestResult>(entityName: "PasswordEntity")
        do {
            passwordEntityFetch.predicate = NSPredicate(format: "parent = %@", parent ?? 0)
            let fetchedPasswordEntities = try context.fetch(passwordEntityFetch) as! [PasswordEntity]
            return fetchedPasswordEntities.sorted { $0.name!.caseInsensitiveCompare($1.name!) == .orderedAscending }
        } catch {
            fatalError("Failed to fetch passwords: \(error)")
        }
    }
    
    func fetchPasswordEntityCoreData(withDir: Bool) -> [PasswordEntity] {
        let passwordEntityFetch = NSFetchRequest<NSFetchRequestResult>(entityName: "PasswordEntity")
        do {
            if !withDir {
                passwordEntityFetch.predicate = NSPredicate(format: "isDir = false")

            }
            let fetchedPasswordEntities = try context.fetch(passwordEntityFetch) as! [PasswordEntity]
            return fetchedPasswordEntities.sorted { $0.name!.caseInsensitiveCompare($1.name!) == .orderedAscending }
        } catch {
            fatalError("Failed to fetch passwords: \(error)")
        }
    }
    
    
    func fetchUnsyncedPasswords() -> [PasswordEntity] {
        let passwordEntityFetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "PasswordEntity")
        passwordEntityFetchRequest.predicate = NSPredicate(format: "synced = %i", 0)
        do {
            let passwordEntities = try context.fetch(passwordEntityFetchRequest) as! [PasswordEntity]
            return passwordEntities
        } catch {
            fatalError("Failed to fetch passwords: \(error)")
        }
    }
    
    func setAllSynced() {
        let passwordEntities = fetchUnsyncedPasswords()
        for passwordEntity in passwordEntities {
            passwordEntity.synced = true
        }
        do {
            if context.hasChanges {
                try context.save()
            }
        } catch {
            fatalError("Failed to save: \(error)")
        }
    }
    
    func getNumberOfUnsyncedPasswords() -> Int {
        let passwordEntityFetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "PasswordEntity")
        do {
            passwordEntityFetchRequest.predicate = NSPredicate(format: "synced = %i", 0)
            return try context.count(for: passwordEntityFetchRequest)
        } catch {
            fatalError("Failed to fetch unsynced passwords: \(error)")
        }
    }
    
    
    func getLatestUpdateInfo(filename: String) -> String {
        guard let blameHunks = try? storeRepository?.blame(withFile: filename, options: nil).hunks,
            let latestCommitTime = blameHunks?.map({
                 $0.finalSignature?.time?.timeIntervalSince1970 ?? 0
            }).max() else {
            return "unknown"
        }
        let lastCommitDate = Date(timeIntervalSince1970: latestCommitTime)
        let currentDate = Date()
        var autoFormattedDifference: String
        if currentDate.timeIntervalSince(lastCommitDate) <= 60 {
            autoFormattedDifference = "Just now"
        } else {
            let diffDate = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: lastCommitDate, to: currentDate)
            let dateComponentsFormatter = DateComponentsFormatter()
            dateComponentsFormatter.unitsStyle = .full
            dateComponentsFormatter.maximumUnitCount = 2
            dateComponentsFormatter.includesApproximationPhrase = true
            autoFormattedDifference = (dateComponentsFormatter.string(from: diffDate)?.appending(" ago"))!
        }
        return autoFormattedDifference
    }
    
    func updateRemoteRepo() {
    }
    
    
    func addEntryToGTTree(fileData: Data, filename: String) -> GTTree {
        do {
            let head = try storeRepository!.headReference()
            let branch = GTBranch(reference: head, repository: storeRepository!)
            let headCommit = try branch?.targetCommit()
            
            let treeBulider = try GTTreeBuilder(tree: headCommit?.tree, repository: storeRepository!)
            try treeBulider.addEntry(with: fileData, fileName: filename, fileMode: GTFileMode.blob)
            
            let newTree = try treeBulider.writeTree()
            return newTree
        } catch {
            fatalError("Failed to add entries to GTTree: \(error)")

        }
    }
    
    func removeEntryFromGTTree(filename: String) -> GTTree {
        do {
            let head = try storeRepository!.headReference()
            let branch = GTBranch(reference: head, repository: storeRepository!)
            let headCommit = try branch?.targetCommit()
            
            let treeBulider = try GTTreeBuilder(tree: headCommit?.tree, repository: storeRepository!)
            try treeBulider.removeEntry(withFileName: filename)
            
            let newTree = try treeBulider.writeTree()
            return newTree
        } catch {
            fatalError("Failed to remove entries to GTTree: \(error)")
            
        }
    }
    
    func createAddCommitInRepository(message: String, fileData: Data, filename: String, progressBlock: (_ progress: Float) -> Void) -> GTCommit? {
        do {
            let newTree = addEntryToGTTree(fileData: fileData, filename: filename)
            let headReference = try storeRepository!.headReference()
            let commitEnum = try GTEnumerator(repository: storeRepository!)
            try commitEnum.pushSHA(headReference.targetOID.sha!)
            let parent = commitEnum.nextObject() as! GTCommit
            progressBlock(0.5)
            let commit = try storeRepository!.createCommit(with: newTree, message: message, parents: [parent], updatingReferenceNamed: headReference.name)
            progressBlock(0.7)
            return commit
        } catch {
            print(error)
        }
        return nil
    }
    
    func createRemoveCommitInRepository(message: String, filename: String, progressBlock: (_ progress: Float) -> Void) -> GTCommit? {
        do {
            let newTree = removeEntryFromGTTree(filename: filename)
            let headReference = try storeRepository!.headReference()
            let commitEnum = try GTEnumerator(repository: storeRepository!)
            try commitEnum.pushSHA(headReference.targetOID.sha!)
            let parent = commitEnum.nextObject() as! GTCommit
            progressBlock(0.5)
            let commit = try storeRepository!.createCommit(with: newTree, message: message, parents: [parent], updatingReferenceNamed: headReference.name)
            progressBlock(0.7)
            return commit
        } catch {
            print(error)
        }
        return nil
    }
    
    
    private func getLocalBranch(withName branchName: String) -> GTBranch? {
        do {
            let reference = GTBranch.localNamePrefix().appending(branchName)
            let branches = try storeRepository!.branches(withPrefix: reference)
            return branches[0]
        } catch {
            print(error)
        }
        return nil
    }
    
    func pushRepository(transferProgressBlock: @escaping (UInt32, UInt32, Int, UnsafeMutablePointer<ObjCBool>) -> Void) throws {
        let credentialProvider = try gitCredential!.credentialProvider()
        let options: [String: Any] = [
            GTRepositoryRemoteOptionsCredentialProvider: credentialProvider,
            ]
        let masterBranch = getLocalBranch(withName: "master")!
        let remote = try GTRemote(name: "origin", in: storeRepository!)
        try storeRepository?.push(masterBranch, to: remote, withOptions: options, progress: transferProgressBlock)
    }
    
    func add(password: Password, progressBlock: (_ progress: Float) -> Void) throws {
        progressBlock(0.0)
        guard !passwordExisted(password: password) else {
            throw NSError(domain: "me.mssun.pass.error", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add password: password duplicated."])
        }
        let passwordEntity = NSEntityDescription.insertNewObject(forEntityName: "PasswordEntity", into: context) as! PasswordEntity
        do {
            let encryptedData = try passwordEntity.encrypt(password: password)
            progressBlock(0.3)
            let saveURL = storeURL.appendingPathComponent("\(password.name).gpg")
            try encryptedData.write(to: saveURL)
            passwordEntity.name = password.name
            passwordEntity.path = "\(password.name).gpg"
            passwordEntity.parent = nil
            passwordEntity.synced = false
            passwordEntity.isDir = false
            try context.save()
            print(saveURL.path)
            let _ = createAddCommitInRepository(message: "Add new password by pass for iOS", fileData: encryptedData, filename: saveURL.lastPathComponent, progressBlock: progressBlock)
            progressBlock(1.0)
        } catch {
            print(error)
        }
    }
    
    func update(passwordEntity: PasswordEntity, password: Password, progressBlock: (_ progress: Float) -> Void) {
        do {
            let encryptedData = try passwordEntity.encrypt(password: password)
            let saveURL = storeURL.appendingPathComponent(passwordEntity.path!)
            try encryptedData.write(to: saveURL)
            progressBlock(0.3)
            let _ = createAddCommitInRepository(message: "Update password by pass for iOS", fileData: encryptedData, filename: saveURL.lastPathComponent, progressBlock: progressBlock)
        } catch {
            print(error)
        }
    }
    
    func saveUpdated(passwordEntity: PasswordEntity) {
        do {
            try context.save()
        } catch {
            fatalError("Failed to save a PasswordEntity: \(error)")
        }
    }
    
    func deleteCoreData(entityName: String) {
        let deleteFetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: deleteFetchRequest)
        
        do {
            try context.execute(deleteRequest)
            try context.save()
            context.reset()
        } catch let error as NSError {
            print(error)
        }
    }
    
    func updateImage(passwordEntity: PasswordEntity, image: Data?) {
        if image == nil {
            return
        }
        let privateMOC = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        privateMOC.parent = context
        privateMOC.perform {
            passwordEntity.image = NSData(data: image!)
            do {
                try privateMOC.save()
                self.context.performAndWait {
                    do {
                        try self.context.save()
                    } catch {
                        fatalError("Failure to save context: \(error)")
                    }
                }
            } catch {
                fatalError("Failure to save context: \(error)")
            }
        }
    }
    
    func erase() {
        Utils.removeFileIfExists(at: storeURL)
        Utils.removeFileIfExists(at: tempStoreURL)

        Utils.removeFileIfExists(atPath: Globals.pgpPublicKeyPath)
        Utils.removeFileIfExists(atPath: Globals.pgpPrivateKeyPath)
        Utils.removeFileIfExists(at: Globals.sshPrivateKeyURL)
        Utils.removeFileIfExists(at: Globals.sshPublicKeyURL)
        
        Utils.removeAllKeychain()

        
        deleteCoreData(entityName: "PasswordEntity")
        
        Defaults.removeAll()
        storeRepository = nil
    }
    
    // return the number of discarded commits 
    func reset() throws -> Int {
        // get the remote origin/master branch
        guard let remoteBranches = try storeRepository?.remoteBranches(),
            let index = remoteBranches.index(where: { $0.shortName == "master" })
            else {
                throw NSError(domain: "me.mssun.pass.error", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot find remote branch origin/master."])
        }
        let remoteMasterBranch = remoteBranches[index]
        //print("remoteMasterBranch \(remoteMasterBranch)")
        
        // get a list of local commits
        if let localCommits = try storeRepository?.localCommitsRelative(toRemoteBranch: remoteMasterBranch),
            localCommits.count > 0 {
            // get the oldest local commit
            guard let firstLocalCommit = localCommits.last,
                firstLocalCommit.parents.count == 1,
                let newHead = firstLocalCommit.parents.first else {
                    throw NSError(domain: "me.mssun.pass.error", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot decide how to reset."])
            }
            try self.storeRepository?.reset(to: newHead, resetType: GTRepositoryResetType.hard)
            self.updatePasswordEntityCoreData()
            NotificationCenter.default.post(Notification(name: Notification.Name("passwordUpdated")))
            self.setAllSynced()
            return localCommits.count
        } else {
            return 0  // no new commit
        }
    }
}
