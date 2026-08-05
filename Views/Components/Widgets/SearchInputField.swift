import SwiftUI

#if os(macOS)
import AppKit

struct SearchInputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    var shouldFocus: Bool = false
    
    init(
        text: Binding<String>,
        placeholder: String = "Search...",
        fontSize: CGFloat = 12,
        shouldFocus: Bool = false
    ) {
        self._text = text
        self.placeholder = placeholder
        self.fontSize = fontSize
        self.shouldFocus = shouldFocus
    }
    
    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = placeholder
        searchField.delegate = context.coordinator
        searchField.bezelStyle = .roundedBezel
        searchField.controlSize = fontSize <= 11 ? .mini : .small
        searchField.focusRingType = .default
        searchField.font = .systemFont(ofSize: fontSize)
        searchField.wantsLayer = true
        searchField.layer?.shadowOpacity = 0
        
        return searchField
    }
    
    func updateNSView(_ nsView: NSSearchField, context: Context) {
        nsView.stringValue = text
        nsView.placeholderString = placeholder
        
        if shouldFocus != context.coordinator.lastFocusState {
            context.coordinator.lastFocusState = shouldFocus
            if shouldFocus {
                DispatchQueue.main.async {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        }
        
        // Handle focus resignation
        if context.coordinator.shouldResignFirstResponder {
            nsView.window?.makeFirstResponder(nil)
            context.coordinator.shouldResignFirstResponder = false
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchInputField
        var shouldResignFirstResponder = false
        var lastFocusState = false
        
        init(_ parent: SearchInputField) {
            self.parent = parent
        }
        
        func controlTextDidChange(_ obj: Notification) {
            if let searchField = obj.object as? NSSearchField {
                parent.text = searchField.stringValue
            }
        }
        
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Handle Escape key to clear focus
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                shouldResignFirstResponder = true
                return true
            }
            return false
        }
    }
}

// MARK: - Preview
#Preview {
    @Previewable @State var searchText = ""
    
    VStack(spacing: 20) {
        SearchInputField(
            text: $searchText,
            placeholder: "Search library...",
            fontSize: 12
        )
        .frame(width: 280)
        
        Text("Search text: \(searchText)")
            .foregroundColor(.secondary)
    }
    .padding()
    .frame(width: 400, height: 200)
}
#else
import UIKit

struct SearchInputField: View {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    var shouldFocus: Bool = false
    
    @FocusState private var isFocused: Bool
    
    init(
        text: Binding<String>,
        placeholder: String = "Search...",
        fontSize: CGFloat = 12,
        shouldFocus: Bool = false
    ) {
        self._text = text
        self.placeholder = placeholder
        self.fontSize = fontSize
        self.shouldFocus = shouldFocus
    }
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: fontSize + 1))
                .foregroundColor(.secondary)
            
            TextField(placeholder, text: $text)
                .font(.system(size: fontSize))
                .focused($isFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: fontSize + 1))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
        )
        .onChange(of: shouldFocus) { _, should in
            if should {
                isFocused = true
            }
        }
    }
}
#endif
