//
//  marmyApp.swift
//  marmy
//
//  Created by Marwan Harajli on 1/17/26.
//

import SwiftUI

@main
struct marmyApp: App {
    init() {
        // Load saved configuration on app launch
        let settingsVM = SettingsViewModel()
        settingsVM.loadSavedConfig()
    }

    var body: some Scene {
        WindowGroup {
            ProjectListView()
        }
    }
}
