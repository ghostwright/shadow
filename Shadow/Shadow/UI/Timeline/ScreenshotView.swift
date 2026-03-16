import SwiftUI

/// Displays the screenshot at the current playhead position with app info below.
struct ScreenshotView: View {
    let image: CGImage?
    let appName: String?
    let windowTitle: String?
    let timestamp: Date

    var body: some View {
        VStack(spacing: 0) {
            if let image {
                Image(decorative: image, scale: 2.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            Text("No screenshot available")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }
            }

            // Metadata strip below image
            if appName != nil || windowTitle != nil {
                HStack(spacing: 8) {
                    if let appName {
                        Text(appName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    if let windowTitle {
                        Text(windowTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(timeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
        }
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: timestamp)
    }
}
