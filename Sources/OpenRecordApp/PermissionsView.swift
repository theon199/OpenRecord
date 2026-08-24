import OpenRecord
import SwiftUI

struct PermissionsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.red)
                Text("Allow OpenRecord to record")
                    .font(.title2.weight(.semibold))
                Text("Screen Recording, Microphone, and Accessibility are required. Accessibility captures the cursor so auto-zoom can work after you stop.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            VStack(spacing: 10) {
                ForEach(CapturePermissionKind.requiredForScreenCapture, id: \.self) { kind in
                    permissionRow(kind)
                }
            }
            .frame(maxWidth: 520)

            HStack(spacing: 12) {
                Button("Recheck") {
                    model.refreshPermissions()
                }
                Button("Request Remaining") {
                    Task {
                        for kind in CapturePermissionKind.requiredForScreenCapture
                            where model.permissionGranted[kind] != true
                        {
                            await model.requestPermission(kind)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func permissionRow(_ kind: CapturePermissionKind) -> some View {
        let granted = model.permissionGranted[kind] == true
        return HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: kind))
                    .font(.headline)
                Text(CapturePermissions.denialMessage(for: kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Text("On")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            } else {
                Button("Open Settings") {
                    Task { await model.requestPermission(kind) }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func title(for kind: CapturePermissionKind) -> String {
        switch kind {
        case .screenRecording: return "Screen Recording"
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .camera: return "Camera"
        }
    }
}
