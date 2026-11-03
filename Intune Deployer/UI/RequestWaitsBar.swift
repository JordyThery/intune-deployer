import JTKit
import SwiftUI

/// A wait before Microsoft is asked again ("Microsoft asked to wait 40 s"),
/// with Stop, which ends every wait at once; those requests aren't sent
/// again. Shown at the bottom of the main window and of the sheets that
/// talk to the tenant.
struct RequestWaitsBar: View {
    let waits: RequestWaits

    var body: some View {
        if let text = waits.statusText {
            HStack(spacing: 8) {
                Label(text, systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { waits.cancelAll() }
                    .help("Ends the wait now; the request isn’t sent again.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }
}
