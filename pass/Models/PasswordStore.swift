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
    var credential: Credential
    
    enum Credential {
        case http(userName: String, password: String, requestGitPassword: ((_ message: String) -> String?)?)
        case ssh(userName: String, password: String, publicKeyFile: URL, privateKeyFile: URL, requestSSHKeyPassword: ((_ message: String) -> String?)? )
    }
    
    init(credential: Credential) {
        self.credential = credential
        Defaults[.gitPasswordAttempts] = 0
    }
    
    func credentialProvider() throws -> GTCredentialProvider {
        return GTCredentialProvider { (_, _, _) -> (GTCredential?) in
            var credential: GTCredential? = nil
            
            switch self.credential {
            case let .http(userName, password, requestGitPassword):
                var newPassword =  password
                if Defaults[.gitPasswordAttempts] != 0 {
                    if let requestGitPasswordCallback = requestGitPassword,
                        let requestedPassword = requestGitPasswordCallback("Please fill in the password of your Git account.") {
                        newPassword	= requestedPassword
                    } else {
                        return nil
                   
                    }
                }
                Defaults[.gitPasswordAttempts] += 1
                credential = try? GTCredential(userName: userName, password: newPassword)
            case let .ssh(userName, password, publicKeyFile, privateKeyFile, requestSSHKeyPassword):
                var newPassword = password
                if Defaults[.gitPasswordAttempts] != 0 {
                    if let requestSSHKeyPasswordCallback = requestSSHKeyPassword,
                        let requestedPassword = requestSSHKeyPasswordCallback("Please fill in the password of your SSH key.") {
                        newPassword	= requestedPassword
                    } else {
                        return nil
                        
                    }
                }
                Defaults[.gitPasswordAttempts] += 1
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
    var pgpKeyID: String?
    var publicKey: PGPKey? {
        didSet {
            if publicKey != nil {
                pgpKeyID = publicKey!.keyID!.shortKeyString
            } else {
                pgpKeyID = nil
            }
        }
    }
    var privateKey: PGPKey?
    
    var gitSignatureForNow: GTSignature {
        get {
            let name = Defaults[.gitName] ?? Defaults[.gitUsername] ?? ""
            let email = Defaults[.gitEmail] ?? (Defaults[.gitUsername] ?? "" + "@passforios")
            return GTSignature(name: name, email: email, time: Date())!
        }
    }
    
    let pgp: ObjectivePGP = ObjectivePGP()
    
    var pgpKeyPassphrase: String? {
        set {
            Utils.addPasswordToKeychain(name: "pgpKeyPassphrase", password: newValue)
        }
        get {
            return Utils.getPasswordFromKeychain(name: "pgpKeyPassphrase")
        }
    }
    var gitPassword: String? {
        set {
            Utils.addPasswordToKeychain(name: "gitPassword", password: newValue)
        }
        get {
            return Utils.getPasswordFromKeychain(name: "gitPassword")
        }
    }
    
    var gitSSHPrivateKeyPassphrase: String? {
        set {
            Utils.addPasswordToKeychain(name: "gitSSHPrivateKeyPassphrase", password: newValue)
        }
        get {
            return Utils.getPasswordFromKeychain(name: "gitSSHPrivateKeyPassphrase") ?? ""
        }
    }
    
    let context = (UIApplication.shared.delegate as! AppDelegate).persistentContainer.viewContext
    
    var numberOfPasswords : Int {
        return self.fetchPasswordEntityCoreData(withDir: false).count 
    }
    
    var sizeOfRepositoryByteCount : UInt64 {
        let fm = FileManager.default
        var size = UInt64(0)
        do {
            if fm.fileExists(atPath: self.storeURL.path) {
                size = try fm.allocatedSizeOfDirectoryAtURL(directoryURL: self.storeURL)
            }
        } catch {
            print(error)
        }
        return size
    }

    
    private init() {
        do {
            if FileManager.default.fileExists(atPath: storeURL.path) {
                try storeRepository = GTRepository.init(url: storeURL)
            }
        } catch {
            print(error)
        }
        initPGPKeys()
        initGitCredential()
    }
    
    enum SSHKeyType {
        case `public`, secret
    }
    
    public func initGitCredential() {
        if Defaults[.gitAuthenticationMethod] == "Password" {
            let httpCredential = GitCredential.Credential.http(userName: Defaults[.gitUsername] ?? "", password: Utils.getPasswordFromKeychain(name: "gitPassword") ?? "", requestGitPassword: nil)
            gitCredential = GitCredential(credential: httpCredential)
        } else if Defaults[.gitAuthenticationMethod] == "SSH Key"{
            gitCredential = GitCredential(
                credential: GitCredential.Credential.ssh(
                    userName: Defaults[.gitUsername] ?? "",
                    password: gitSSHPrivateKeyPassphrase ?? "",
                    publicKeyFile: Globals.gitSSHPublicKeyURL,
                    privateKeyFile: Globals.gitSSHPrivateKeyURL,
                    requestSSHKeyPassword: nil
                )
            )
        } else {
            gitCredential = nil
        }
    }
    
    public func initGitSSHKey(with armorKey: String, _ keyType: SSHKeyType) throws {
        var keyPath = ""
        switch keyType {
        case .public:
            keyPath = Globals.gitSSHPublicKeyPath
        case .secret:
            keyPath = Globals.gitSSHPrivateKeyPath
        }
        
        try armorKey.write(toFile: keyPath, atomically: true, encoding: .ascii)
    }
    
    public func initPGPKeys() {
        do {
            try initPGPKey(.public)
            try initPGPKey(.secret)
        } catch {
            print(error)
        }
    }
    
    public func initPGPKey(_ keyType: PGPKeyType) throws {
        switch keyType {
        case .public:
            let keyPath = Globals.pgpPublicKeyPath
            self.publicKey = importKey(from: keyPath)
            if self.publicKey == nil {
                throw NSError(domain: "me.mssun.pass.error", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot import the public PGP key."])
            }
        case .secret:
            let keyPath = Globals.pgpPrivateKeyPath
            self.privateKey = importKey(from: keyPath)
            if self.privateKey == nil  {
                throw NSError(domain: "me.mssun.pass.error", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot import the private PGP key."])
            }
        default:
            throw NSError(domain: "me.mssun.pass.error", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot import key: unknown PGP key type."])
        }
    }
    
    public func initPGPKey(from url: URL, keyType: PGPKeyType) throws{
        var pgpKeyLocalPath = ""
        if keyType == .public {
            pgpKeyLocalPath = Globals.pgpPublicKeyPath
        } else {
            pgpKeyLocalPath = Globals.pgpPrivateKeyPath
        }
        let pgpKeyData = try Data(contentsOf: url)
        try pgpKeyData.write(to: URL(fileURLWithPath: pgpKeyLocalPath), options: .atomic)
        try initPGPKey(keyType)
    }
    
    public func initPGPKey(with armorKey: String, keyType: PGPKeyType) throws {
        var pgpKeyLocalPath = ""
        if keyType == .public {
            pgpKeyLocalPath = Globals.pgpPublicKeyPath
        } else {
            pgpKeyLocalPath = Globals.pgpPrivateKeyPath
        }
        try armorKey.write(toFile: pgpKeyLocalPath, atomically: true, encoding: .ascii)
        try initPGPKey(keyType)
    }
    
    
    private func importKey(from keyPath: String) -> PGPKey? {
        let fm = FileManager.default
        if fm.fileExists(atPath: keyPath) {
            if let keys = pgp.importKeys(fromFile: keyPath, allowDuplicates: false) as? [PGPKey] {
                return keys.first
            }
        }
        return nil
    }

    func getPgpPrivateKey() -> PGPKey {
        return pgp.getKeysOf(.secret)[0]
    }
    
    func repositoryExisted() -> Bool {
        let fm = FileManager()
        return fm.fileExists(atPath: Globals.repositoryPath)
    }
    
    func passwordExisted(password: Password) -> Bool {
        let passwordEntityFetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "PasswordEntity")
        do {
            passwordEntityFetchRequest.predicate = NSPredicate(format: "name = %@ and path = %@", password.name, password.url!.path)
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
    
    func passwordEntityExisted(path: String) -> Bool {
        let passwordEntityFetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "PasswordEntity")
        do {
            passwordEntityFetchRequest.predicate = NSPredicate(format: "path = %@", path)
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
    
    func getPasswordEntity(by path: String) -> PasswordEntity? {
        let passwordEntityFetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "PasswordEntity")
        do {
            passwordEntityFetchRequest.predicate = NSPredicate(format: "path = %@", path)
            return try context.fetch(passwordEntityFetchRequest).first as? PasswordEntity
        } catch {
            fatalError("Failed to fetch password entities: \(error)")
        }
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
        Defaults[.lastSyncedTime] = Date()
        DispatchQueue.main.async {
            self.updatePasswordEntityCoreData()
            NotificationCenter.default.post(name: .passwordStoreUpdated, object: nil)
        }
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
        Defaults[.lastSyncedTime] = Date()
        DispatchQueue.main.async {
            self.setAllSynced()
            self.updatePasswordEntityCoreData()
            NotificationCenter.default.post(name: .passwordStoreUpdated, object: nil)
        }
    }
    
    private func updatePasswordEntityCoreData() {
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
        guard storeRepository != nil else {
            return []
        }
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
    
    private func gitAdd(path: String) throws {
        if let repo = storeRepository {
            try repo.index().addFile(path)
            try repo.index().write()
        }
    }
    
    private func gitRm(path: String) throws {
        if let repo = storeRepository {
            var url = storeURL.appendingPathComponent(path)
            Utils.removeFileIfExists(at: url)
            let fm = FileManager.default
            url.deleteLastPathComponent()
            var count = try fm.contentsOfDirectory(atPath: url.path).count
            while count == 0 {
                Utils.removeFileIfExists(atPath: url.path)
                url.deleteLastPathComponent()
                count = try fm.contentsOfDirectory(atPath: url.path).count
            }
            try repo.index().removeFile(path)
            try repo.index().write()
        }
    }
    
    private func gitMv(from: String, to: String) throws {
        let fm = FileManager.default
        try fm.moveItem(at: storeURL.appendingPathComponent(from), to: storeURL.appendingPathComponent(to))
        try gitAdd(path: to)
        try gitRm(path: from)
    }
    
    private func gitCommit(message: String) throws -> GTCommit? {
        if let repo = storeRepository {
            let newTree = try repo.index().writeTree()
            let headReference = try repo.headReference()
            let commitEnum = try GTEnumerator(repository: repo)
            try commitEnum.pushSHA(headReference.targetOID.sha!)
            let parent = commitEnum.nextObject() as! GTCommit
            let signature = gitSignatureForNow
            let commit = try repo.createCommit(with: newTree, message: message, author: signature, committer: signature, parents: [parent], updatingReferenceNamed: headReference.name)
            return commit
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
    
    private func addPasswordEntities(password: Password) throws -> PasswordEntity? {
        guard !passwordExisted(password: password) else {
            throw NSError(domain: "me.mssun.pass.error", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add password: password duplicated."])
        }
        
        var passwordURL = password.url!
        var paths: [String] = []
        while passwordURL.path != "." {
            paths.append(passwordURL.path)
            passwordURL = passwordURL.deletingLastPathComponent()
        }
        paths.reverse()
        var parentPasswordEntity: PasswordEntity? = nil
        for path in paths {
            if let passwordEntity = getPasswordEntity(by: path) {
                parentPasswordEntity = passwordEntity
            } else {
                if path.hasSuffix(".gpg") {
                    return insertPasswordEntity(name: URL(string: path)!.deletingPathExtension().lastPathComponent, path: path, parent: parentPasswordEntity, synced: false, isDir: false)
                } else {
                    parentPasswordEntity = insertPasswordEntity(name: URL(string: path)!.lastPathComponent, path: path, parent: parentPasswordEntity, synced: false, isDir: true)
                    let fm = FileManager.default
                    let saveURL = storeURL.appendingPathComponent(path)
                    do {
                        try fm.createDirectory(at: saveURL, withIntermediateDirectories: false, attributes: nil)
                    } catch {
                        print(error)
                    }
                }
            }
        }
        return nil
    }
    
    private func insertPasswordEntity(name: String, path: String, parent: PasswordEntity?, synced: Bool = false, isDir: Bool = false) -> PasswordEntity? {
        var ret: PasswordEntity? = nil
        if let passwordEntity = NSEntityDescription.insertNewObject(forEntityName: "PasswordEntity", into: self.context) as? PasswordEntity {
            passwordEntity.name = name
            passwordEntity.path = path
            passwordEntity.parent = parent
            passwordEntity.synced = synced
            passwordEntity.isDir = isDir
            do {
                try self.context.save()
                ret = passwordEntity
            } catch {
                fatalError("Failed to insert a PasswordEntity: \(error)")
            }
        }
        return ret
    }
    
    func add(password: Password) throws -> PasswordEntity? {
        let newPasswordEntity = try addPasswordEntities(password: password)
        let saveURL = storeURL.appendingPathComponent(password.url!.path)
        try self.encrypt(password: password).write(to: saveURL)
        try gitAdd(path: password.url!.path)
        let _ = try gitCommit(message: "Add password for \(password.url!.deletingPathExtension().path) to store using Pass for iOS.")
        NotificationCenter.default.post(name: .passwordStoreUpdated, object: nil)
        return newPasswordEntity
    }
    
    func edit(passwordEntity: PasswordEntity, password: Password) throws -> PasswordEntity? {
        var newPasswordEntity: PasswordEntity? = passwordEntity

        if password.changed&PasswordChange.content.rawValue != 0 {
            let saveURL = storeURL.appendingPathComponent(password.url!.path)
            try self.encrypt(password: password).write(to: saveURL)
            try gitAdd(path: password.url!.path)
            let _ = try gitCommit(message: "Edit password for \(password.url!.deletingPathExtension().path) to store using Pass for iOS.")
        }
        guard newPasswordEntity != nil else {
            return nil
        }
        if password.changed&PasswordChange.path.rawValue != 0 {
            let oldPasswordURL = newPasswordEntity!.getURL()
            try self.deletePasswordEntities(passwordEntity: newPasswordEntity!)
            newPasswordEntity = try self.addPasswordEntities(password: password)
            try gitMv(from: oldPasswordURL!.path, to: password.url!.path)
            let _ = try gitCommit(message: "Rename \(oldPasswordURL!.deletingPathExtension().path) to \(password.url!.deletingPathExtension().path) using Pass for iOS.")
        }
        return newPasswordEntity
    }
    
    private func deletePasswordEntities(passwordEntity: PasswordEntity) throws {
        var current: PasswordEntity? = passwordEntity
        while current != nil && (current!.children!.count == 0 || !current!.isDir) {
            let parent = current!.parent
            self.context.delete(current!)
            current = parent
            do {
                try self.context.save()
            } catch {
                fatalError("Failed to delete a PasswordEntity: \(error)")
            }
        }
    }
    
    public func delete(passwordEntity: PasswordEntity) throws {
        try gitRm(path: passwordEntity.path!)
        let _ = try gitCommit(message: "Remove \(passwordEntity.nameWithCategory) from store using Pass for iOS.")
        try deletePasswordEntities(passwordEntity: passwordEntity)
        NotificationCenter.default.post(name: .passwordStoreUpdated, object: nil)
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
        publicKey = nil
        privateKey = nil
        Utils.removeFileIfExists(at: storeURL)
        Utils.removeFileIfExists(at: tempStoreURL)

        Utils.removeFileIfExists(atPath: Globals.pgpPublicKeyPath)
        Utils.removeFileIfExists(atPath: Globals.pgpPrivateKeyPath)
        Utils.removeFileIfExists(atPath: Globals.gitSSHPublicKeyPath)
        Utils.removeFileIfExists(atPath: Globals.gitSSHPrivateKeyPath)
        
        Utils.removeAllKeychain()

        
        deleteCoreData(entityName: "PasswordEntity")
        
        Defaults.removeAll()
        storeRepository = nil
        
        NotificationCenter.default.post(name: .passwordStoreUpdated, object: nil)
        NotificationCenter.default.post(name: .passwordStoreErased, object: nil)
    }
    
    // return the number of discarded commits 
    func reset() throws -> Int {
        // get a list of local commits
        if let localCommits = try getLocalCommits(),
            localCommits.count > 0 {
            // get the oldest local commit
            guard let firstLocalCommit = localCommits.last,
                firstLocalCommit.parents.count == 1,
                let newHead = firstLocalCommit.parents.first else {
                    throw NSError(domain: "me.mssun.pass.error", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot decide how to reset."])
            }
            try self.storeRepository?.reset(to: newHead, resetType: GTRepositoryResetType.hard)
            self.setAllSynced()
            self.updatePasswordEntityCoreData()
            Defaults[.lastSyncedTime] = nil
            
            NotificationCenter.default.post(name: .passwordStoreUpdated, object: nil)
            NotificationCenter.default.post(name: .passwordStoreChangeDiscarded, object: nil)
            return localCommits.count
        } else {
            return 0  // no new commit
        }
    }
    
    func numberOfLocalCommits() -> Int {
        do {
            if let localCommits = try getLocalCommits() {
                return localCommits.count
            } else {
                return 0
            }
        } catch {
            print(error)
        }
        return 0
    }
    
    private func getLocalCommits() throws -> [GTCommit]? {
        // get the remote origin/master branch
        guard let remoteBranches = try storeRepository?.remoteBranches(),
            let index = remoteBranches.index(where: { $0.shortName == "master" })
            else {
                throw NSError(domain: "me.mssun.pass.error", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot find remote branch origin/master."])
        }
        let remoteMasterBranch = remoteBranches[index]
        //print("remoteMasterBranch \(remoteMasterBranch)")
        
        // get a list of local commits
        return try storeRepository?.localCommitsRelative(toRemoteBranch: remoteMasterBranch)
    }
    
    
    
    func decrypt(passwordEntity: PasswordEntity, requestPGPKeyPassphrase: () -> String) throws -> Password? {
        var password: Password?
        let encryptedDataPath = URL(fileURLWithPath: "\(Globals.repositoryPath)/\(passwordEntity.path!)")
        let encryptedData = try Data(contentsOf: encryptedDataPath)
        var passphrase = self.pgpKeyPassphrase
        if passphrase == nil {
            passphrase = requestPGPKeyPassphrase()
        }
        let decryptedData = try PasswordStore.shared.pgp.decryptData(encryptedData, passphrase: passphrase)
        let plainText = String(data: decryptedData, encoding: .utf8) ?? ""
        password = Password(name: passwordEntity.name!, url: URL(string: passwordEntity.path!), plainText: plainText)
        return password
    }
    
    func encrypt(password: Password) throws -> Data {
        let plainData = password.getPlainData()
        let pgp = PasswordStore.shared.pgp
        let encryptedData = try pgp.encryptData(plainData, usingPublicKey: pgp.getKeysOf(.public)[0], armored: Defaults[.encryptInArmored])
        return encryptedData
    }
}
