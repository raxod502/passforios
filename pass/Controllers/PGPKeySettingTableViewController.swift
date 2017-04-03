//
//  PGPKeySettingTableViewController.swift
//  pass
//
//  Created by Mingshen Sun on 21/1/2017.
//  Copyright © 2017 Bob Sun. All rights reserved.
//

import UIKit
import SwiftyUserDefaults

class PGPKeySettingTableViewController: UITableViewController {

    @IBOutlet weak var pgpPublicKeyURLTextField: UITextField!
    @IBOutlet weak var pgpPrivateKeyURLTextField: UITextField!
    var pgpPassphrase: String?
    let passwordStore = PasswordStore.shared
    
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableViewAutomaticDimension
        pgpPublicKeyURLTextField.text = Defaults[.pgpPublicKeyURL]?.absoluteString
        pgpPrivateKeyURLTextField.text = Defaults[.pgpPrivateKeyURL]?.absoluteString
        pgpPassphrase = passwordStore.pgpKeyPassphrase
    }
    
    override func shouldPerformSegue(withIdentifier identifier: String, sender: Any?) -> Bool {
        if identifier == "savePGPKeySegue" {
            guard let pgpPublicKeyURL = URL(string: pgpPublicKeyURLTextField.text!) else {
                Utils.alert(title: "Cannot Save", message: "Please set Public Key URL first.", controller: self, completion: nil)
                return false
            }
            guard let pgpPrivateKeyURL = URL(string: pgpPrivateKeyURLTextField.text!) else {
                Utils.alert(title: "Cannot Save", message: "Please set Private Key URL first.", controller: self, completion: nil)
                return false
            }
            guard pgpPublicKeyURL.scheme! == "https", pgpPrivateKeyURL.scheme! == "https"  else {
                Utils.alert(title: "Cannot Save Settings", message: "HTTP connection is not supported.", controller: self, completion: nil)
                return false
            }
        }
        return true
    }
    
    @IBAction func save(_ sender: Any) {
        let alert = UIAlertController(title: "Passphrase", message: "Please fill in the passphrase of your PGP secret key.", preferredStyle: UIAlertControllerStyle.alert)
        alert.addAction(UIAlertAction(title: "OK", style: UIAlertActionStyle.default, handler: {_ in
            self.pgpPassphrase = alert.textFields?.first?.text
            if self.shouldPerformSegue(withIdentifier: "savePGPKeySegue", sender: self) {
                self.performSegue(withIdentifier: "savePGPKeySegue", sender: self)
            }
        }))
        alert.addTextField(configurationHandler: {(textField: UITextField!) in
            textField.text = self.pgpPassphrase
            textField.isSecureTextEntry = true
        })
        self.present(alert, animated: true, completion: nil)
    }
}
