//
//  OnboardingView.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import SwiftUI

struct OnboardingView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Onboarding Required")
                .font(.title2)
                .bold()
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("I’ve been onboarded — Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

#Preview {
    OnboardingView(message: "Your identity needs to be linked by an administrator before you can sign in.", retry: {})
}
