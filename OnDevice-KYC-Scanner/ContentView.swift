//
//  ContentView.swift
//  OnDevice-KYC-Scanner
//
//  Created by Jonrel Baclayon on 7/20/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var coordinator = OnboardingCoordinatorViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.isUnlocked {
                    LandingView()
                } else {
                    LoginView(onUnlock: coordinator.unlock)
                }
            }
            .animation(.snappy, value: coordinator.isUnlocked)
        }
        .onAppear {
            coordinator.lockIfSessionExpired()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                coordinator.lockIfSessionExpired()
            }
        }
    }
}
