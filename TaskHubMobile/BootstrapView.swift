//
//  BootstrapView.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import SwiftUI

struct BootstrapView: View {
    @EnvironmentObject private var env: DefaultAppEnvironment
    @State private var inputURL: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var meta: ServerMeta?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Task Hub Server")) {
                    TextField("https://your.taskhub.example", text: $inputURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityIdentifier("bootstrap.url")
                }

                if let meta {
                    Section("Detected Server") {
                        LabeledContent("API Version", value: String(meta.api_version))
                        LabeledContent("OIDC Client ID", value: meta.oidc_client_id)
                        LabeledContent("Discovery URL", value: meta.oidc_discovery_url.absoluteString)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button(action: validateAndSave) {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Connect")
                        }
                    }
                    .disabled(isLoading)
                    .accessibilityIdentifier("bootstrap.connect")
                }
            }
            .navigationTitle("Connect to Task Hub")
        }
    }

    private func validateAndSave() {
        errorMessage = nil
        meta = nil

        let trimmedInput = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = ServerBootstrap.normalizeBaseURL(from: trimmedInput) else {
            errorMessage = BootstrapError.invalidURL.errorDescription
            return
        }

        isLoading = true
        Task {
            do {
                let m = try await ServerBootstrap.validate(baseURL: url)
                await MainActor.run {
                    meta = m
                    env.appConfig.setBaseURL(url)
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

#Preview {
    BootstrapView()
        .environmentObject(DefaultAppEnvironment())
}
