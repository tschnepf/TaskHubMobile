//
//  BootstrapView.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import SwiftUI

struct BootstrapView: View {
    @EnvironmentObject private var appConfig: AppConfig
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
                }
            }
            .navigationTitle("Connect to Task Hub")
        }
    }

    private func validateAndSave() {
        print("[UI] Connect tapped with text:", inputURL.debugDescription)
        errorMessage = nil
        meta = nil
        let trimmedInput = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[Bootstrap] Trimmed input:", trimmedInput.debugDescription)
        guard let url = ServerBootstrap.normalizeBaseURL(from: trimmedInput) else {
            errorMessage = BootstrapError.invalidURL.errorDescription
            return
        }
        print("[Bootstrap] Normalized base URL:", url.absoluteString)
        isLoading = true
        Task {
            let healthURL = url.appendingPathComponent("health/live").absoluteString
            let metaURL = url.appendingPathComponent("api/mobile/v1/meta").absoluteString
            print("[Bootstrap] Will GET:", healthURL, "and", metaURL)
            do {
                let m = try await ServerBootstrap.validate(baseURL: url)
                await MainActor.run {
                    self.meta = m
                    self.appConfig.setBaseURL(url)
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

#Preview {
    BootstrapView()
        .environmentObject(AppConfig())
}
