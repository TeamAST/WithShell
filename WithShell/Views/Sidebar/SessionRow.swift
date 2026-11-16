import SwiftUI

struct SessionRow: View {
    let session: SessionProfile
    var showsFolder = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.kind.systemImage)
                .foregroundStyle(session.kind == .ssh ? Color.green : Color.blue)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .help(session.notes.isEmpty ? session.addressDescription : session.notes)
    }

    private var subtitle: String {
        if showsFolder, let folder = session.folder {
            return "\(folder.name) · \(session.addressDescription)"
        }
        return session.addressDescription
    }
}
