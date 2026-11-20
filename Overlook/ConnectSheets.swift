import SwiftUI

struct ManualConnectSheet: View {
    @Binding var isPresented: Bool
    @Binding var hostPort: String
    @Binding var port: String
    @Binding var password: String
    @Binding var rememberPassword: Bool

    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manual Connect")
                .font(.headline)

            TextField("Host or IP (optionally host:port)", text: $hostPort)
                .textFieldStyle(.roundedBorder)

            TextField("Port", text: $port)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            Toggle("Remember password in Keychain", isOn: $rememberPassword)
                .disabled(password.isEmpty)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button("Connect") {
                    onConnect()
                    isPresented = false
                }
                .disabled(hostPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

struct PasswordPromptSheet: View {
    @Binding var isPresented: Bool
    @Binding var password: String
    @Binding var rememberPassword: Bool

    let message: String

    let onCancel: () -> Void
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password Required")
                .font(.headline)

            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            Toggle("Remember password in Keychain", isOn: $rememberPassword)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    isPresented = false
                }
                Button("Connect") {
                    onConnect()
                    isPresented = false
                }
                .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
