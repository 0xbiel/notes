import Foundation

/// Translate app-owned status/error text at display time, including older saved chats.
/// User prompts and provider prose are never rewritten here.
enum NotebookAssistantText {
    static func display(_ text: String, language: String) -> String {
        if language != "en" {
            let attachmentErrors = [
                "Choose a regular file, not a folder or link.": "Elige un archivo, no una carpeta ni un enlace.",
                "Attachments must be 20 MB or smaller.": "Los archivos adjuntos no pueden superar 20 MB.",
                "Attachments must contain data and be 20 MB or smaller.": "El archivo debe contener datos y no superar 20 MB.",
                "This PDF is locked or cannot be read.": "El PDF está bloqueado o no se puede leer.",
                "Attach a PDF with 24 pages or fewer. Split larger PDFs before attaching them.": "Adjunta un PDF de hasta 24 páginas. Divide los PDF más grandes antes de adjuntarlos.",
                "A PDF page could not be read.": "No se pudo leer una página del PDF.",
                "A PDF page could not be rendered.": "No se pudo mostrar una página del PDF.",
                "Unsupported file type. Attach images, PDFs, DOCX, RTF, or UTF-8 text/code files. Export other documents as PDF or text first.": "Formato no compatible. Adjunta imágenes, PDF, DOCX, RTF o archivos de texto/código UTF-8. Exporta otros documentos a PDF o texto.",
                "This file contains too much text. Split it into smaller files before attaching it.": "El archivo contiene demasiado texto. Divídelo antes de adjuntarlo.",
                "This image cannot be read.": "No se puede leer esta imagen.",
                "Could not prepare image.": "No se pudo preparar la imagen.",
                "Could not read pasted attachment.": "No se pudo leer el archivo pegado.",
                "Attach up to 8 files per message.": "Adjunta hasta 8 archivos por mensaje.",
                "Attach up to 8 files and 24 images/PDF pages per message.": "Adjunta hasta 8 archivos y 24 imágenes/páginas PDF por mensaje.",
                "Attachment context exceeds 24 images/pages or belongs to another notebook. Start a new chat for more attachments.": "Los adjuntos superan 24 imágenes/páginas o pertenecen a otro cuaderno. Inicia otro chat para añadir más.",
                "Prepared images exceed 32 MB. Attach fewer images or PDF pages.": "Las imágenes preparadas superan 32 MB. Adjunta menos imágenes o páginas PDF.",
                "This provider does not support image/PDF attachments. Select Codex or Antigravity.": "Este proveedor no admite imágenes/PDF adjuntos. Selecciona Codex o Antigravity.",
                "This provider does not support image/PDF attachments. Select Codex or an image-capable Antigravity provider.": "Este proveedor no admite imágenes/PDF adjuntos. Selecciona Codex o Antigravity con soporte de imágenes.",
                "This provider does not advertise image support. Choose an image-capable provider to send these attachments.": "Este proveedor no indica soporte de imágenes. Selecciona un proveedor compatible para enviar estos adjuntos."
            ]
            return attachmentErrors[text] ?? text
        }
        let replacements = [
            "Respuesta simulada inválida: ": "",
            "La copia cambió fuera de esta sesión. No se sobrescribió; abre una sesión nueva o revisa el conflicto.": "The document changed outside this operation. Nothing was overwritten. Review the conflict before retrying.",
            "Ruta rechazada por la protección de copia:": "Path rejected by workspace protection:",
            "Restaura primero el cuaderno desde la papelera.": "Restore the notebook from Trash first.",
            "Crea o restaura un cuaderno primero.": "Create or restore a notebook first.",
            "La carpeta contiene archivos que no son Markdown; muévelos antes de eliminarla.": "The folder contains non-Markdown files. Move them before deleting it.",
            "El asistente repitió una petición de contexto. Acota la petición y vuelve a enviar.": "The assistant requested the same context again. No files were changed. Please retry.",
            "Petición interrumpida. Revisa el historial antes de volver a enviar.": "Request interrupted. Check the history before sending again.",
            "La petición necesita demasiado contexto. Acótala para continuar.": "The request needs more context than one operation can retrieve. Narrow it down to continue.",
            "El contexto supera el límite de esta petición. Inicia un chat nuevo o acota los documentos.": "The context exceeds this request's limit. Start a new chat or narrow down the documents.",
            "La edición necesita un fragmento exacto y único de un documento leído.": "The edit needs an exact, unique passage from a document the assistant has read.",
            "La referencia legal necesita una fuente BOE verificada antes de editar.": "This legal reference needs a verified BOE source before editing.",
            "No se pudo verificar el artículo en BOE. No se ha insertado texto legal.": "The article could not be verified with BOE. No legal text was inserted.",
            "La norma BOE no coincide con la ley solicitada. Confirma la ley.": "The BOE source does not match the requested law. Please confirm the law.",
            "Artículo ausente o ambiguo en la norma. Indica el artículo exacto.": "The article is missing or ambiguous. Please specify the exact article.",
            "Indica la ley o su enlace BOE para resolver el artículo.": "Specify the law or its BOE link to look up the article.",
            "El artículo recibido no coincide con la referencia.": "The retrieved article does not match the reference.",
            "El artículo no tiene una versión verificable en esa fecha.": "No verifiable version of this article is available for that date.",
            "El artículo no contiene texto verificable.": "The article contains no verifiable text.",
            "Activa las fuentes BOE en el perfil del cuaderno.": "Enable BOE sources in the notebook profile.",
            "El asistente pidió contexto y cambios a la vez.": "The assistant requested context and edits in the same response.",
            "Documento solicitado inexistente:": "Requested document does not exist:",
            "El archivo no pertenece a este cuaderno:": "The file does not belong to this notebook:",
            "La transacción necesita recuperación:": "The transaction needs recovery:",
            "No se pudo guardar el mensaje:": "Could not save the message:",
            "BOE no encontró la norma o el artículo.": "BOE could not find the law or article.",
            "Identificador de artículo inválido.": "Invalid article identifier.",
            "Fecha histórica inválida.": "Invalid historical date.",
            "Respuesta BOE demasiado grande.": "The BOE response is too large.",
            "Fuente legal ausente o edición demasiado grande.": "Missing legal source or edit too large.",
            "Archivo repetido en la respuesta.": "Duplicate file in the response.",
            "Respuesta del asistente inválida.": "Invalid assistant response.",
            "Chat no disponible.": "Chat is unavailable.",
            "Versión dañada.": "Damaged checkpoint.",
            "Versión desconocida.": "Unknown checkpoint.",
            "Archivo sin cuaderno.": "File has no notebook.",
            "Cambios duplicados o vacíos.": "Duplicate or empty changes.",
            "Creación inválida.": "Invalid file creation.",
            "Petición cancelada.": "Request cancelled.",
            "Leyendo el cuaderno…": "Reading notebook…",
            "Preparando cambios…": "Preparing changes…",
            "Consultando BOE": "Looking up BOE",
            "Leyendo ·": "Reading ·",
            "Validando y guardando": "Validating and saving",
            "Cambios guardados": "Changes saved",
            "archivo(s)": "file(s)",
            "Sin cambios.": "No changes."
        ]
        return replacements.keys.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: replacements[$1]!) }
    }
}
