import Photos
import SwiftUI

struct AlbumPickerView: View {
    @EnvironmentObject private var model: PhotoBackupViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""

    private var filteredAlbums: [PhotoBackupViewModel.AlbumRow] {
        let all = model.availableAlbums
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Choose Albums")
                    .font(.system(.title2, design: .rounded).bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .denied {
                    Text("Photos access is denied. Enable it in System Settings → Privacy & Security → Photos.")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .font(.system(.caption, design: .rounded))
                }

                List(filteredAlbums, id: \.localIdentifier) { album in
                    Button {
                        if model.selectedAlbumIds.contains(album.localIdentifier) {
                            model.selectedAlbumIds.remove(album.localIdentifier)
                        } else {
                            model.selectedAlbumIds.insert(album.localIdentifier)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.selectedAlbumIds.contains(album.localIdentifier) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.selectedAlbumIds.contains(album.localIdentifier) ? DesignSystem.Colors.accentPrimary : DesignSystem.Colors.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.title)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.92))
                                Text("\(album.estimatedCount) item(s)")
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
        .onAppear {
            model.refreshAlbumsIfPossible()
        }
    }
}

