/// Native browser dialogs can live inside a large browser window. Search the
/// browser UI, never the web document (including ARIA dialogs authored by it).
public enum NativeDialogSurface {
    public static func isDialog(role: String, subrole: String) -> Bool {
        role == "AXSheet" || role == "AXDialog"
            || subrole == "AXDialog" || subrole == "AXApplicationDialog"
            || subrole == "AXApplicationAlertDialog"
    }

    public static func shouldDescend(role: String) -> Bool {
        role != "AXWebArea"
    }
}
