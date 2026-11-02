import Foundation

public enum NotebookCustomUI {
    public static let fileSuffix = ".ui.html"
    public static func isCustomUI(_ path: String) -> Bool { path.hasSuffix(fileSuffix) }
    public static func validate(_ source: String) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf8.count <= 1_000_000, !source.contains("\0") else {
            throw MediaError.invalid("Custom UI must contain HTML and fit within 1 MB.")
        }
    }
    public static let instructions = """
    Embedded UI in Markdown: when the user wants a custom UI inside an existing .md note, use edits on that note and place self-contained HTML in a fenced html-ui block, surrounded by ordinary Markdown. Palladium renders this block in View mode and shows its exact source in Edit mode. Raw standalone <section>, <div>, <article>, <details> and similar container blocks also render, and standalone <style> definitions in the note apply to its HTML blocks. Each block is an isolated frame: keep its required scripts, markup and data together; do not rely on another block's DOM. Use the same notebook theme variables and capabilities described below. Ordinary fenced html code samples remain literal code. Prefer embedding for a requested change to an existing note; create a separate .ui.html only for a requested standalone view. HTML inside Markdown remains source text in PDF/print output for now.
    Custom notebook UI: when asked for a custom interactive view, calculator, dashboard or specialized interface, create outputs with format="html", a new notebook-scoped .ui.html path, sourcePath="", source=the self-contained HTML, and page/crop/test=null. The view opens embedded in the notebook. Use semantic HTML, accessible labels and inline JavaScript for local interactions; include all data required by the task. No external libraries, fonts, network requests, file access, app tools, navigation or persistent browser storage are available. Interaction state lasts while the view is open; do not promise saved entries or changes to notes. Keep the layout responsive and consistent with Palladium: system font, restrained spacing, subtle borders and rounded controls. Use the host's CSS variables for ALL colors: --notebook-background, --notebook-surface, --notebook-text, --notebook-secondary, --notebook-border, --notebook-accent, --notebook-on-accent. Use --notebook-radius and --notebook-font for shape and typography. Never hardcode light/dark palettes or request a mode toggle: Palladium updates these tokens and color-scheme live. data-theme on the document root is light or dark. Semantic elements (buttons, inputs, tables, sections) receive matching default styles; use class="primary" for an accent action. Custom CSS may arrange content but must preserve these theme tokens. No shell is necessary. Read required notebook sources before constructing grounded content. Link the .ui.html from a note if helpful. Read existing .ui.html views with readFiles and update them with edits (replaceEntireFile=true for a complete rewrite). Standard practice tests continue to use native quiz output unless the user specifically requests custom HTML.
    """

    /// The generated document runs in an opaque-origin frame with no native bridge,
    /// filesystem base URL, network access, forms, popups or parent-page access.
    public static func document(source: String, theme: [String: String], embedded: Bool = false) -> String {
        func attribute(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let variables = theme.filter { $0.key.hasPrefix("--notebook-") }.sorted { $0.key < $1.key }
            .map { $0.key + ":" + $0.value + ";" }.joined()
        let mode = theme["mode"] == "dark" ? "dark" : "light"
        let child = """
        <!doctype html><html data-theme="\(mode)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        :root { \(variables) color-scheme: \(mode); --notebook-font: -apple-system, BlinkMacSystemFont, sans-serif; --notebook-radius: 10px; }
        * { box-sizing: border-box; }
        html, body { background: var(--notebook-background) !important; color: var(--notebook-text) !important; font-family: var(--notebook-font) !important; margin: 0; }
        body { display: flow-root; padding: \(embedded ? "0" : "28px 28px calc(28px + var(--notebook-bottom-inset, 0px))"); line-height: 1.55; font-size: \(embedded ? "16" : "15")px; overflow-wrap: anywhere; }
        h1 { font-size: 26px; line-height: 1.2; } h2 { font-size: 20px; } h3 { font-size: 17px; }
        h1,h2,h3 { font-weight: 600; } p { margin: 0 0 1em; }
        small, figcaption, .secondary { color: var(--notebook-secondary); }
        a { color: var(--notebook-accent); }
        section, fieldset, .card { background: var(--notebook-surface); border: 1px solid var(--notebook-border); border-radius: var(--notebook-radius); padding: 18px; margin-block: 14px; min-width: 0; }
        button, input, select, textarea { font: inherit; color: var(--notebook-text); background: var(--notebook-surface); border: 1px solid var(--notebook-border); border-radius: var(--notebook-radius); padding: 8px 12px; max-width: 100%; accent-color: var(--notebook-accent); }
        button { cursor: pointer; } button.primary { background: var(--notebook-accent); color: var(--notebook-on-accent); border-color: transparent; }
        button:disabled { opacity: .45; cursor: default; } :focus-visible { outline: 2px solid var(--notebook-accent); outline-offset: 2px; }
        table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
        th,td { text-align: start; padding: 10px 12px; border-bottom: 1px solid var(--notebook-border); } th { color: var(--notebook-secondary); font-weight: 500; }
        hr { border: 0; border-top: 1px solid var(--notebook-border); } img,svg,canvas { max-width: 100%; }
        @media (max-width: 480px) { body { padding-inline: 16px; } th,td { padding: 8px 6px; } }
        @media (prefers-reduced-motion: reduce) { *,*::before,*::after { animation: none !important; transition: none !important; scroll-behavior: auto !important; } }
        </style>
        <script>
        window.addEventListener('message', event => {
          if (event.source !== parent || event.data?.type !== 'palladium-theme') return;
          const theme = event.data.theme;
          for (const [key, value] of Object.entries(theme)) {
            if (key.startsWith('--notebook-')) document.documentElement.style.setProperty(key, value);
          }
          document.documentElement.dataset.theme = theme.mode;
          document.documentElement.style.colorScheme = theme.mode;
          window.dispatchEvent(new Event('palladium-theme-change'));
        });
        </script></head><body>\(source)
        \(embedded ? Self.sizeReporter : "")</body></html>
        """
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src about:; base-uri 'none'; form-action 'none'">
        <style>html,body{margin:0;height:100%;overflow:hidden;background:\(theme["--notebook-background"] ?? "transparent")}iframe{width:100%;height:100%;border:0;display:block}</style>
        </head><body><iframe title="Notebook custom view" sandbox="allow-scripts" srcdoc="\(attribute(child))"></iframe></body></html>
        """
    }

    private static let sizeReporter = """
    <script>
    (() => {
      let pending = false;
      const report = () => {
        if (pending) return; pending = true;
        setTimeout(() => {
          pending = false;
          parent.postMessage({type:'palladium-size',height:Math.ceil(document.body.getBoundingClientRect().height)}, '*');
        }, 0);
      };
      new ResizeObserver(report).observe(document.body);
      new MutationObserver(report).observe(document.body, {subtree:true, childList:true, attributes:true, characterData:true});
      window.addEventListener('load', report);
      report();
    })();
    </script>
    """
}
