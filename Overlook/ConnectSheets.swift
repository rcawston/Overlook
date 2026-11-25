import SwiftUI

struct ManualConnectSheet: View {
    @Binding var isPresented: Bool
    @Binding var hostPort: String
    @Binding var port: String
    @Binding var password: String

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

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    onConnect()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
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

    let onCancel: () -> Void
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password Required")
                .font(.headline)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    onConnect()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
