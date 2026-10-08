import SwiftUI

struct AIOption: Identifiable {
    let id: String
    let title: String
    var badge: String? = nil
}

struct AIOptionSelector: View {
    let title: String
    let symbol: String
    let options: [AIOption]
    @Binding var selection: String
    @State private var presented = false
    @State private var hovered: String?

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(options.first { $0.id == selection }?.title ?? selection)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.font(.callout).padding(.horizontal, 9).padding(.vertical, 8)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(selection)
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                    ForEach(options) { option in
                        Button {
                            selection = option.id; presented = false
                        } label: {
                            HStack(spacing: 5) {
                                Text(option.title).font(.system(size: 13))
                                if let badge = option.badge {
                                    Text(badge).font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1)
                                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.primary.opacity(0.2)))
                                }
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                                .background(selection == option.id || hovered == option.id ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).onHover { hovered = $0 ? option.id : nil }
                            .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                    }
                }.padding(5).frame(minWidth: 154).fixedSize(horizontal: true, vertical: true)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .onExitCommand { presented = false }
            }
    }
}
