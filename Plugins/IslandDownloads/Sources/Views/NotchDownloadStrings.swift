// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Vorssaint (github.com/vorssaint/vorssaint-utils), GPL-3.0-or-later.
// Copyright (C) 2026 Vorssaint; MacTools adaptation (C) 2026 MacTools contributors.

import Foundation
import MacToolsPluginKit

/// Vorssaint's Downloads words (`NotchFilesStrings`) with its Open and
/// Show in Finder labels, in every language it ships.
struct NotchDownloadStrings {
    let saved: String
    let downloadsTitle: String
    let downloadsDescription: String
    let downloadsHint: String
    let chooseFolder: String
    let folderUnavailable: String
    let waiting: String
    let inProgress: String
    let totalUnknown: String
    let completed: String
    let clearFolder: String
    let open: String
    let showInFinder: String
}

extension NotchDownloadStrings {
    static let enUS = NotchDownloadStrings(
        saved: "Saved",
        downloadsTitle: "Downloads",
        downloadsDescription: "See files arriving in a folder you choose, directly in the Dynamic Island.",
        downloadsHint: "Choose the folder where your browser saves downloads. Only that folder is watched.",
        chooseFolder: "Choose Folder…",
        folderUnavailable: "This folder is unavailable. Choose it again to restore access.",
        waiting: "No files in this folder",
        inProgress: "Downloading",
        totalUnknown: "Total size unavailable",
        completed: "Download complete",
        clearFolder: "Forget Folder",
        open: "Open",
        showInFinder: "Show")
    static let ptBR = NotchDownloadStrings(
        saved: "Salvo",
        downloadsTitle: "Downloads",
        downloadsDescription: "Veja os arquivos chegando em uma pasta escolhida, direto no Dynamic Island.",
        downloadsHint: "Escolha a pasta onde seu navegador salva os downloads. Só essa pasta será acompanhada.",
        chooseFolder: "Escolher pasta…",
        folderUnavailable: "A pasta está indisponível. Escolha novamente para recuperar o acesso.",
        waiting: "Nenhum arquivo nesta pasta",
        inProgress: "Baixando",
        totalUnknown: "Tamanho total indisponível",
        completed: "Download concluído",
        clearFolder: "Esquecer pasta",
        open: "Abrir",
        showInFinder: "Mostrar")
    static let es = NotchDownloadStrings(
        saved: "Guardado",
        downloadsTitle: "Descargas",
        downloadsDescription: "Ve los archivos que llegan a una carpeta elegida, directamente en el Dynamic Island.",
        downloadsHint: "Elige la carpeta donde tu navegador guarda las descargas. Solo se supervisa esa carpeta.",
        chooseFolder: "Elegir carpeta…",
        folderUnavailable: "La carpeta no está disponible. Elígela de nuevo para recuperar el acceso.",
        waiting: "No hay archivos en esta carpeta",
        inProgress: "Descargando",
        totalUnknown: "Tamaño total no disponible",
        completed: "Descarga completada",
        clearFolder: "Olvidar carpeta",
        open: "Abrir",
        showInFinder: "Mostrar")
    static let sk = NotchDownloadStrings(
        saved: "Uložené",
        downloadsTitle: "Stiahnuté",
        downloadsDescription: "Sledujte súbory prichádzajúce do vybraného priečinka priamo v Dynamic Island.",
        downloadsHint: "Vyberte priečinok, kam váš prehliadač ukladá stiahnuté súbory. Sleduje sa iba tento priečinok.",
        chooseFolder: "Vybrať priečinok…",
        folderUnavailable: "Tento priečinok nie je dostupný. Vyberte ho znova, aby ste obnovili prístup.",
        waiting: "V tomto priečinku nie sú žiadne súbory",
        inProgress: "Sťahovanie",
        totalUnknown: "Celková veľkosť nie je dostupná",
        completed: "Sťahovanie dokončené",
        clearFolder: "Zabudnúť priečinok",
        open: "Otvoriť",
        showInFinder: "Zobraziť")
    static let de = NotchDownloadStrings(
        saved: "Gesichert",
        downloadsTitle: "Downloads",
        downloadsDescription: "Sieh direkt im Dynamic Island, welche Dateien in einem ausgewählten Ordner ankommen.",
        downloadsHint: "Wähle den Ordner, in dem dein Browser Downloads sichert. Nur dieser Ordner wird beobachtet.",
        chooseFolder: "Ordner auswählen…",
        folderUnavailable: "Der Ordner ist nicht verfügbar. Wähle ihn erneut aus, um den Zugriff wiederherzustellen.",
        waiting: "Keine Dateien in diesem Ordner",
        inProgress: "Wird geladen",
        totalUnknown: "Gesamtgröße nicht verfügbar",
        completed: "Download abgeschlossen",
        clearFolder: "Ordner vergessen",
        open: "Öffnen",
        showInFinder: "Anzeigen")
    static let fr = NotchDownloadStrings(
        saved: "Enregistré",
        downloadsTitle: "Téléchargements",
        downloadsDescription: "Voyez les fichiers arriver dans un dossier choisi, directement dans le Dynamic Island.",
        downloadsHint: "Choisissez le dossier où votre navigateur enregistre les téléchargements. Seul ce dossier est suivi.",
        chooseFolder: "Choisir un dossier…",
        folderUnavailable: "Ce dossier est indisponible. Choisissez-le à nouveau pour rétablir l’accès.",
        waiting: "Aucun fichier dans ce dossier",
        inProgress: "Téléchargement",
        totalUnknown: "Taille totale indisponible",
        completed: "Téléchargement terminé",
        clearFolder: "Oublier le dossier",
        open: "Ouvrir",
        showInFinder: "Afficher")
    static let it = NotchDownloadStrings(
        saved: "Salvato",
        downloadsTitle: "Download",
        downloadsDescription: "Vedi i file in arrivo in una cartella scelta, direttamente nel Dynamic Island.",
        downloadsHint: "Scegli la cartella in cui il browser salva i download. Viene monitorata solo quella cartella.",
        chooseFolder: "Scegli cartella…",
        folderUnavailable: "La cartella non è disponibile. Sceglila di nuovo per ripristinare l’accesso.",
        waiting: "Nessun file in questa cartella",
        inProgress: "Download in corso",
        totalUnknown: "Dimensione totale non disponibile",
        completed: "Download completato",
        clearFolder: "Dimentica cartella",
        open: "Apri",
        showInFinder: "Mostra")
    static let ru = NotchDownloadStrings(
        saved: "Сохранено",
        downloadsTitle: "Загрузки",
        downloadsDescription: "Следите за файлами, поступающими в выбранную папку, прямо в вырезе.",
        downloadsHint: "Выберите папку, в которую браузер сохраняет загрузки. Отслеживается только эта папка.",
        chooseFolder: "Выбрать папку…",
        folderUnavailable: "Папка недоступна. Выберите её снова, чтобы восстановить доступ.",
        waiting: "В этой папке нет файлов",
        inProgress: "Загрузка",
        totalUnknown: "Общий размер недоступен",
        completed: "Загрузка завершена",
        clearFolder: "Забыть папку",
        open: "Открыть",
        showInFinder: "Показать")
    static let tr = NotchDownloadStrings(
        saved: "Kaydedildi",
        downloadsTitle: "İndirmeler",
        downloadsDescription: "Seçtiğiniz klasöre gelen dosyaları doğrudan çentikte görün.",
        downloadsHint: "Tarayıcınızın indirmeleri kaydettiği klasörü seçin. Yalnızca bu klasör izlenir.",
        chooseFolder: "Klasör seç…",
        folderUnavailable: "Bu klasöre erişilemiyor. Erişimi yeniden sağlamak için tekrar seçin.",
        waiting: "Bu klasörde dosya yok",
        inProgress: "İndiriliyor",
        totalUnknown: "Toplam boyut bilinmiyor",
        completed: "İndirme tamamlandı",
        clearFolder: "Klasörü unut",
        open: "Aç",
        showInFinder: "Göster")
    static let ja = NotchDownloadStrings(
        saved: "保存済み",
        downloadsTitle: "ダウンロード",
        downloadsDescription: "選択したフォルダに届くファイルをDynamic Islandで確認できます。",
        downloadsHint: "ブラウザのダウンロード保存先フォルダを選択してください。このフォルダのみを監視します。",
        chooseFolder: "フォルダを選択…",
        folderUnavailable: "このフォルダは利用できません。アクセスを復元するには、もう一度選択してください。",
        waiting: "このフォルダにはファイルがありません",
        inProgress: "ダウンロード中",
        totalUnknown: "合計サイズは不明です",
        completed: "ダウンロード完了",
        clearFolder: "フォルダの選択を解除",
        open: "開く",
        showInFinder: "表示")
    static let ko = NotchDownloadStrings(
        saved: "저장됨",
        downloadsTitle: "다운로드",
        downloadsDescription: "선택한 폴더에 도착하는 파일을 Dynamic Island에서 바로 확인하세요.",
        downloadsHint: "브라우저가 다운로드를 저장하는 폴더를 선택하세요. 해당 폴더만 확인합니다.",
        chooseFolder: "폴더 선택…",
        folderUnavailable: "이 폴더를 사용할 수 없습니다. 접근 권한을 복원하려면 다시 선택하세요.",
        waiting: "이 폴더에 파일 없음",
        inProgress: "다운로드 중",
        totalUnknown: "전체 크기를 알 수 없음",
        completed: "다운로드 완료",
        clearFolder: "폴더 선택 해제",
        open: "열기",
        showInFinder: "Finder에서 보기")
    static let zhHans = NotchDownloadStrings(
        saved: "已保存",
        downloadsTitle: "下载",
        downloadsDescription: "直接在Dynamic Island中查看文件下载到所选文件夹的情况。",
        downloadsHint: "选择浏览器保存下载文件的文件夹。仅监视此文件夹。",
        chooseFolder: "选择文件夹…",
        folderUnavailable: "此文件夹不可用。请重新选择以恢复访问。",
        waiting: "此文件夹中没有文件",
        inProgress: "正在下载",
        totalUnknown: "总大小未知",
        completed: "下载完成",
        clearFolder: "忘记文件夹",
        open: "打开",
        showInFinder: "显示")
    static let zhTW = NotchDownloadStrings(
        saved: "已儲存",
        downloadsTitle: "下載",
        downloadsDescription: "直接在Dynamic Island中查看檔案下載到所選檔案夾的情況。",
        downloadsHint: "選擇瀏覽器儲存下載檔案的檔案夾。只會監看此檔案夾。",
        chooseFolder: "選擇檔案夾…",
        folderUnavailable: "此檔案夾無法使用。請重新選擇以恢復存取。",
        waiting: "此檔案夾中沒有檔案",
        inProgress: "正在下載",
        totalUnknown: "總大小未知",
        completed: "下載完成",
        clearFolder: "忘記檔案夾",
        open: "打開",
        showInFinder: "顯示")
    static let zhHK = NotchDownloadStrings(
        saved: "已儲存",
        downloadsTitle: "下載",
        downloadsDescription: "直接在Dynamic Island中查看檔案下載到所選資料夾的情況。",
        downloadsHint: "選擇瀏覽器儲存下載檔案的資料夾。只會監察此資料夾。",
        chooseFolder: "選擇資料夾…",
        folderUnavailable: "此資料夾無法使用。請重新選擇以恢復取用。",
        waiting: "此資料夾中沒有檔案",
        inProgress: "正在下載",
        totalUnknown: "總大小不詳",
        completed: "下載完成",
        clearFolder: "忘記資料夾",
        open: "開啟",
        showInFinder: "顯示")
    static let uk = NotchDownloadStrings(
        saved: "Збережено",
        downloadsTitle: "Завантаження",
        downloadsDescription: "Стежте за файлами, які надходять до вибраної папки, прямо у Dynamic Island.",
        downloadsHint: "Виберіть папку, куди ваш браузер зберігає завантаження. Відстежується лише ця папка.",
        chooseFolder: "Вибрати папку…",
        folderUnavailable: "Ця папка недоступна. Виберіть її знову, щоб відновити доступ.",
        waiting: "У цій папці немає файлів",
        inProgress: "Завантаження",
        totalUnknown: "Загальний розмір недоступний",
        completed: "Завантаження завершено",
        clearFolder: "Забути папку",
        open: "Відкрити",
        showInFinder: "Показати")

    /// Picked by the language MacTools runs in, as the AI page picks its own.
    static var current: NotchDownloadStrings {
        for language in PluginRuntimeLocalization.preferredLanguages {
            let code = language.lowercased()
            if code.hasPrefix("zh-hant-hk") || code.hasPrefix("zh-hk") { return .zhHK }
            if code.hasPrefix("zh-hant") || code.hasPrefix("zh-tw") { return .zhTW }
            if code.hasPrefix("zh") { return .zhHans }
            switch code.prefix(2) {
            case "en": return .enUS
            case "pt": return .ptBR
            case "es": return .es
            case "sk": return .sk
            case "de": return .de
            case "fr": return .fr
            case "it": return .it
            case "ru": return .ru
            case "tr": return .tr
            case "ja": return .ja
            case "ko": return .ko
            case "uk": return .uk
            default: continue
            }
        }
        return .enUS
    }
}
