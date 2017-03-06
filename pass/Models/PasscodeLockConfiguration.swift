//
//  PasscodeLockConfiguration.swift
//  pass
//
//  Created by Mingshen Sun on 7/2/2017.
//  Copyright © 2017 Bob Sun. All rights reserved.
//

import Foundation
import PasscodeLock
import SwiftyUserDefaults

struct PasscodeLockConfiguration: PasscodeLockConfigurationType {
    
    let repository: PasscodeRepositoryType
    let passcodeLength = 4
    var isTouchIDAllowed = Defaults[.isTouchIDOn]
    let shouldRequestTouchIDImmediately = true
    let maximumInccorectPasscodeAttempts = 3
    
    init(repository: PasscodeRepositoryType) {
        
        self.repository = repository
    }
    
    init() {
        
        self.repository = PasscodeLockRepository()
    }
}
