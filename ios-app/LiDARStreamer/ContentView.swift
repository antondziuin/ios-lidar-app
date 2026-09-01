import SwiftUI

struct ContentView: View {
    @StateObject private var manager = ARSessionManager()
    @FocusState private var focusedField: Field?

    private enum Field {
        case host
        case port
    }

    var body: some View {
        ZStack {
            if manager.isLiDARSupported {
                ARPreviewView(session: manager.session)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack {
                header
                Spacer()
                controls
            }
            .padding()
        }
        .onAppear {
            manager.startCamera()
        }
        .onDisappear {
            manager.stopCamera()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("LiDAR Streamer")
                    .font(.headline)
                Text(manager.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !manager.stats.isEmpty {
                    Text(manager.stats)
                        .font(.caption.monospaced())
                }
            }
            Spacer()
            Circle()
                .fill(manager.isStreaming ? Color.green : (manager.isConnecting ? Color.yellow : Color.gray))
                .frame(width: 12, height: 12)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let errorMessage = manager.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                TextField("IP ПК", text: $manager.host)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .host)
                    .padding(10)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

                TextField("Порт", text: $manager.port)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .port)
                    .frame(width: 88)
                    .padding(10)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }

            Button(action: {
                focusedField = nil
                manager.toggleStreaming()
            }) {
                Text(manager.isStreaming || manager.isConnecting ? "Стоп" : "Старт")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(manager.isStreaming || manager.isConnecting ? .red : .blue)
            .disabled(!manager.isLiDARSupported)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
