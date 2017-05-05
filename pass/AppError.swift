//
//  AppError.swift
//  pass
//
//  Created by Mingshen Sun on 30/4/2017.
//  Copyright © 2017 Bob Sun. All rights reserved.
//

import Foundation

enum AppError: Error {
    case RepositoryNotSetError
    case RepositoryRemoteMasterNotFoundError
    case KeyImportError
    case PasswordDuplicatedError
    case GitResetError
    case PGPPublicKeyNotExistError
    case UnknownError
    
    var localizedDescription: String {
        switch self {
        case .RepositoryNotSetError:
            return "Git repository is not set."
        case .RepositoryRemoteMasterNotFoundError:
            return "Cannot find remote branch origin/master."
        case .KeyImportError:
            return "Cannot import the key."
        case .PasswordDuplicatedError:
            return "Cannot add the password: password duplicated."
        case .GitResetError:
            return "Cannot identify the latest synced commit."
        case .PGPPublicKeyNotExistError:
            return "PGP public key doesn't exist."
        case .UnknownError:
            return "Unknown error."
        }
    }
}
