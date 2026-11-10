import AgentKit
import SwiftUI

struct ModelServerSettings: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Model servers")
                ModelServerList(opensPage: true)
                Hint("Hoply polls each server every 5 seconds while the panel or Dashboard is open, every 30 seconds otherwise, and keeps its history for the Local model page. Add and Edit open in the Dashboard window, which stays up while you copy a key from elsewhere.")
            }
        }
    }
}
