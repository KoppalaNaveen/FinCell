import sys
import os
from reportlab.lib.pagesizes import letter
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, KeepTogether, HRFlowable
)
from reportlab.pdfgen import canvas

class NumberedCanvas(canvas.Canvas):
    """
    Two-pass canvas to add running headers, footers, and page numbers (Page X of Y).
    """
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._saved_page_states = []

    def showPage(self):
        self._saved_page_states.append(dict(self.__dict__))
        self._startPage()

    def save(self):
        num_pages = len(self._saved_page_states)
        for state in self._saved_page_states:
            self.__dict__.update(state)
            self.draw_header_footer(num_pages)
            super().showPage()
        super().save()

    def draw_header_footer(self, page_count):
        self.saveState()
        self.setFont("Helvetica-Bold", 8)
        self.setFillColor(colors.HexColor("#475569"))

        # Running Header (on pages > 1)
        if self._pageNumber > 1:
            self.drawString(40, 755, "FINCELL — Technical Architecture & Competitive Analysis Report")
            self.drawRightString(572, 755, "CONFIDENTIAL")
            self.setStrokeColor(colors.HexColor("#CBD5E1"))
            self.setLineWidth(0.75)
            self.line(40, 747, 572, 747)

        # Running Footer (all pages)
        self.setFont("Helvetica", 8.5)
        self.setFillColor(colors.HexColor("#64748B"))
        self.drawString(40, 28, "FinCell Platform | Flutter, Native Android & Cloud Backend")
        page_text = f"Page {self._pageNumber} of {page_count}"
        self.drawRightString(572, 28, page_text)
        self.setStrokeColor(colors.HexColor("#CBD5E1"))
        self.setLineWidth(0.75)
        self.line(40, 40, 572, 40)

        self.restoreState()

def generate_report(filename):
    doc = SimpleDocTemplate(
        filename,
        pagesize=letter,
        leftMargin=40,
        rightMargin=40,
        topMargin=45,
        bottomMargin=48
    )

    styles = getSampleStyleSheet()

    # Palette
    PRIMARY = colors.HexColor("#0F172A")       # Slate 900
    SECONDARY = colors.HexColor("#0D9488")     # Teal 600
    ACCENT = colors.HexColor("#2563EB")        # Blue 600
    TEXT_DARK = colors.HexColor("#1E293B")     # Slate 800
    BG_LIGHT = colors.HexColor("#F8FAFC")      # Slate 50
    BORDER_COLOR = colors.HexColor("#E2E8F0")  # Slate 200

    # Typography
    title_style = ParagraphStyle(
        'DocTitle',
        parent=styles['Heading1'],
        fontName='Helvetica-Bold',
        fontSize=22,
        leading=26,
        textColor=PRIMARY,
        spaceAfter=4
    )

    subtitle_style = ParagraphStyle(
        'DocSubTitle',
        parent=styles['Normal'],
        fontName='Helvetica',
        fontSize=11,
        leading=15,
        textColor=SECONDARY,
        spaceAfter=10
    )

    h1_style = ParagraphStyle(
        'H1',
        parent=styles['Heading1'],
        fontName='Helvetica-Bold',
        fontSize=13,
        leading=17,
        textColor=PRIMARY,
        spaceBefore=10,
        spaceAfter=6,
        keepWithNext=True
    )

    h2_style = ParagraphStyle(
        'H2',
        parent=styles['Heading2'],
        fontName='Helvetica-Bold',
        fontSize=10.5,
        leading=14,
        textColor=SECONDARY,
        spaceBefore=8,
        spaceAfter=3,
        keepWithNext=True
    )

    body_style = ParagraphStyle(
        'Body',
        parent=styles['Normal'],
        fontName='Helvetica',
        fontSize=9,
        leading=13,
        textColor=TEXT_DARK,
        spaceAfter=5
    )

    bullet_style = ParagraphStyle(
        'Bullet',
        parent=body_style,
        leftIndent=10,
        firstLineIndent=-6,
        spaceAfter=3
    )

    table_header_style = ParagraphStyle(
        'TableHeader',
        parent=styles['Normal'],
        fontName='Helvetica-Bold',
        fontSize=8.5,
        leading=11,
        textColor=colors.white,
        alignment=0
    )

    table_cell_style = ParagraphStyle(
        'TableCell',
        parent=styles['Normal'],
        fontName='Helvetica',
        fontSize=8,
        leading=11,
        textColor=TEXT_DARK
    )

    table_cell_bold = ParagraphStyle(
        'TableCellBold',
        parent=table_cell_style,
        fontName='Helvetica-Bold',
        textColor=PRIMARY
    )

    callout_style = ParagraphStyle(
        'CalloutText',
        parent=styles['Normal'],
        fontName='Helvetica',
        fontSize=8.5,
        leading=12.5,
        textColor=TEXT_DARK
    )

    story = []

    # Title & Metadata Banner
    story.append(Paragraph("FinCell — Anti-Theft & Device Intelligence System", title_style))
    story.append(Paragraph("Detailed Project Implementation Report & Comparative Benchmark vs. Apple Find My & Google Find My", subtitle_style))
    story.append(HRFlowable(width="100%", thickness=1.5, color=SECONDARY, spaceBefore=0, spaceAfter=8))

    # Executive Summary Box
    summary_text = (
        "<b>Executive Summary:</b> FinCell is a security application combining a <b>Flutter multi-platform frontend</b>, "
        "a persistent <b>Native Android Kotlin background service</b>, and a <b>Firebase Cloud infrastructure</b>. "
        "Unlike reactive item locators such as Apple Find My or Google Find My, FinCell acts as an <b>active anti-theft countermeasure</b>. "
        "It equips stolen devices with <i>stealth surveillance (silent camera/audio), off-grid SMS fallback execution, AI movement trajectory prediction, "
        "tamper alerts (SIM removal/charger disconnect), and stealth application launcher hiding</i>."
    )
    summary_table = Table([[Paragraph(summary_text, callout_style)]], colWidths=[532])
    summary_table.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, -1), colors.HexColor("#F0FDFA")),
        ('BORDER', (0, 0), (-1, -1), 1, colors.HexColor("#99F6E4")),
        ('PADDING', (0, 0), (-1, -1), 7),
        ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
    ]))
    story.append(summary_table)
    story.append(Spacer(1, 6))

    # Section 1: Detailed Breakdown of Implemented Features
    story.append(Paragraph("1. Implemented System Features & Technical Architecture", h1_style))
    story.append(HRFlowable(width="100%", thickness=0.5, color=BORDER_COLOR, spaceBefore=0, spaceAfter=6))

    features_list = [
        ("A. Persistent Native Background Tracking Engine", [
            "<b>Native Android Service (<code>LocationForegroundService.kt</code>):</b> Implements sticky foreground service with low battery overhead using <code>FusedLocationProviderClient</code> and <code>PowerManager.WakeLock</code>.",
            "<b>Auto-Reboot Recovery (<code>BootReceiver.kt</code>):</b> Automatically restarts the tracking service instantly upon device reboot via <code>RECEIVE_BOOT_COMPLETED</code>.",
            "<b>Stealth App Masking (<code>AppVisibilityManager.kt</code>):</b> Hides the FinCell app launcher icon from the Android app drawer, blocking unauthorized uninstallation or termination by thieves."
        ]),
        ("B. Proactive Anti-Theft & Physical Tamper Detection", [
            "<b>SIM Removal / Swap Detection:</b> Monitors <code>SIM_STATE_CHANGED</code> broadcast intents to trigger alerts and location capture immediately upon SIM ejection.",
            "<b>Charger Disconnect Trigger:</b> Listens to <code>ACTION_POWER_DISCONNECTED</code> to detect when a locked device is unplugged.",
            "<b>Accelerometer & Proximity Sensors:</b> Detects sudden physical movement, device falls, and pocket removal attempts while screen is locked."
        ]),
        ("C. Stealth Forensic Evidence Gathering", [
            "<b>Silent Dual-Camera Capture (<code>SilentCameraManager.kt</code>):</b> Captures front and rear photos without visual preview windows or shutter sounds using CameraX/Camera2 APIs.",
            "<b>Background Audio Recording:</b> Captures 30-second ambient sound clips via <code>MediaRecorder</code> and uploads encrypted media files directly to Firebase Storage."
        ]),
        ("D. Off-Grid Encrypted SMS Command Engine (<code>CodeService.dart</code>)", [
            "<b>SMS Control Bridge:</b> Operates independently of mobile data or Wi-Fi status.",
            "<b>Secret SMS Triggers:</b> Responds to encrypted text commands (e.g. <code>#LOC#</code>, <code>#CAM#</code>, <code>#ALARM#</code>, <code>#LOCK#</code>, <code>#ERASE#</code>) by automatically capturing and returning SMS location coordinates."
        ]),
        ("E. Hybrid Environment Scanner & Indoor Positioning (<code>EnvironmentScannerService.dart</code>)", [
            "<b>Wi-Fi BSSID & BLE Scanning:</b> Scans nearby Wi-Fi access points and Bluetooth Low Energy beacons for accurate indoor positioning when GPS signal is blocked.",
            "<b>Cellular Tower Triangulation:</b> Collects Cell ID (CID), Mobile Country Code (MCC), Mobile Network Code (MNC), and Location Area Code (LAC) for hybrid triangulation."
        ]),
        ("F. Algorithmic Movement & Trajectory Prediction (<code>MovementPredictionService.dart</code>)", [
            "<b>Velocity Vector & Compass Bearing:</b> Calculates real-time speed ($v_{km/h}$) and movement heading ($\theta$).",
            "<b>Heuristic Destination Forecasting:</b> Predicts probable destinations (Highway, Railway Station, Bus Stand, Airport, Market) based on direction and speed vectors."
        ]),
        ("G. Remote Lost Mode & Emergency Siren (<code>LostModeService.dart</code>)", [
            "<b>Max-Volume Siren Override:</b> Triggers high-pitch emergency alarm overriding device silent/Do-Not-Disturb modes.",
            "<b>Lock Screen Recovery Overlay:</b> Displays custom owner contact phone number and emergency return instructions directly on lock screen."
        ]),
        ("H. Security Timeline & Offline Resilience (<code>TheftTimelineService.dart</code> & <code>OfflineLocationService.dart</code>)", [
            "<b>Chronological Security Audit Log:</b> Records all theft alerts, location pings, camera captures, and SIM swaps in a clean timeline view.",
            "<b>Local SQLite Offline Queue:</b> Caches telemetry locally during network outages and flushes records to Cloud Firestore automatically when reconnected."
        ])
    ]

    for title, points in features_list:
        story.append(Paragraph(title, h2_style))
        for pt in points:
            story.append(Paragraph(f"• {pt}", bullet_style))

    story.append(Spacer(1, 8))

    # Section 2: Detailed Feature Comparison Matrix
    story.append(Paragraph("2. In-Depth Comparison: FinCell vs. Apple Find My vs. Google Find My", h1_style))
    story.append(HRFlowable(width="100%", thickness=0.5, color=BORDER_COLOR, spaceBefore=0, spaceAfter=6))

    story.append(Paragraph(
        "The following matrix benchmarks FinCell against market-leading device locators across critical security, evidence collection, and off-grid dimensions:", body_style
    ))
    story.append(Spacer(1, 4))

    table_data = [
        [
            Paragraph("Dimension", table_header_style),
            Paragraph("FinCell (Our Implementation)", table_header_style),
            Paragraph("Apple Find My", table_header_style),
            Paragraph("Google Find My Device", table_header_style)
        ],
        [
            Paragraph("Core Architecture", table_cell_bold),
            Paragraph("Active Anti-Theft & Forensic Defense Engine", table_cell_style),
            Paragraph("Passive Crowd-Sourced Bluetooth Mesh Network", table_cell_style),
            Paragraph("Passive Crowd-Sourced Bluetooth Mesh Network", table_cell_style)
        ],
        [
            Paragraph("Covert Photography", table_cell_bold),
            Paragraph("<b>Supported:</b> Silent front/rear photo snap sent to Cloud", table_cell_style),
            Paragraph("Not Supported (OS Privacy Constraints)", table_cell_style),
            Paragraph("Not Supported (OS Privacy Constraints)", table_cell_style)
        ],
        [
            Paragraph("Ambient Audio Recording", table_cell_bold),
            Paragraph("<b>Supported:</b> 30s background audio clip upload", table_cell_style),
            Paragraph("Not Supported", table_cell_style),
            Paragraph("Not Supported", table_cell_style)
        ],
        [
            Paragraph("Off-Grid Command Control", table_cell_bold),
            Paragraph("<b>Supported:</b> Secret SMS triggers (#LOC#, #CAM#)", table_cell_style),
            Paragraph("<b>Supported:</b> Offline BLE relay via nearby Apple devices", table_cell_style),
            Paragraph("<b>Supported:</b> Offline BLE relay via nearby Android devices", table_cell_style)
        ],
        [
            Paragraph("SIM Removal Detection", table_cell_bold),
            Paragraph("<b>Supported:</b> Instant alert + silent snap upon SIM pull", table_cell_style),
            Paragraph("No active alert (Relies on passive mesh)", table_cell_style),
            Paragraph("No active alert (Relies on passive mesh)", table_cell_style)
        ],
        [
            Paragraph("Charger Disconnect Alert", table_cell_bold),
            Paragraph("<b>Supported:</b> Alerts when power unplugged while locked", table_cell_style),
            Paragraph("Not Supported", table_cell_style),
            Paragraph("Not Supported", table_cell_style)
        ],
        [
            Paragraph("App Launcher Hiding", table_cell_bold),
            Paragraph("<b>Supported:</b> Hides icon from launcher drawer", table_cell_style),
            Paragraph("Not Applicable (Built into System Settings)", table_cell_style),
            Paragraph("Not Applicable (Built into System Settings)", table_cell_style)
        ],
        [
            Paragraph("Movement Prediction", table_cell_bold),
            Paragraph("<b>Supported:</b> Speed vector + destination forecasting", table_cell_style),
            Paragraph("Not Supported (Shows pin history only)", table_cell_style),
            Paragraph("Not Supported (Shows pin history only)", table_cell_style)
        ],
        [
            Paragraph("Environment Scanning", table_cell_bold),
            Paragraph("<b>Supported:</b> Wi-Fi BSSID + BLE + Cell Tower ID logs", table_cell_style),
            Paragraph("Internal OS location stack only", table_cell_style),
            Paragraph("Internal OS location stack only", table_cell_style)
        ],
        [
            Paragraph("Offline Telemetry Queue", table_cell_bold),
            Paragraph("<b>Supported:</b> Local SQLite storage with auto-sync", table_cell_style),
            Paragraph("Limited internal caching", table_cell_style),
            Paragraph("Limited internal caching", table_cell_style)
        ],
        [
            Paragraph("Ecosystem Lock-in", table_cell_bold),
            Paragraph("Cross-Platform (Flutter + Custom Firebase Backend)", table_cell_style),
            Paragraph("Locked to Apple Hardware Ecosystem", table_cell_style),
            Paragraph("Locked to Android / Google Play Services", table_cell_style)
        ]
    ]

    comp_table = Table(table_data, colWidths=[110, 145, 138, 139])
    comp_table.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, 0), PRIMARY),
        ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
        ('VALIGN', (0, 0), (-1, -1), 'TOP'),
        ('GRID', (0, 0), (-1, -1), 0.5, colors.HexColor("#CBD5E1")),
        ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.white, BG_LIGHT]),
        ('TOPPADDING', (0, 0), (-1, -1), 4.5),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 4.5),
        ('LEFTPADDING', (0, 0), (-1, -1), 5),
        ('RIGHTPADDING', (0, 0), (-1, -1), 5),
    ]))

    story.append(comp_table)
    story.append(Spacer(1, 8))

    # Section 3: Key Strategic Advantages
    story.append(Paragraph("3. Strategic Advantages & Innovation Summary", h1_style))
    story.append(HRFlowable(width="100%", thickness=0.5, color=BORDER_COLOR, spaceBefore=0, spaceAfter=6))

    adv_text = [
        ("1. Active Defense vs. Passive Tracking:", "While Apple and Google help users locate misplaced items, FinCell assumes the phone is in the hands of an active thief. It proactively counteracts evasive actions such as turning off mobile data or ejecting the SIM card."),
        ("2. Forensic Evidence Collection:", "By capturing secret front/rear photos of the suspect, ambient audio recordings, and Wi-Fi/Cell Tower environment fingerprints, FinCell constructs an encrypted cloud evidence file to assist law enforcement in asset recovery."),
        ("3. Direct SMS Off-Grid Bridge:", "Apple and Google depend on nearby third-party Bluetooth devices to relay location. FinCell provides direct SMS command execution over standard cellular channels (#LOC#, #CAM#, #ALARM#), delivering true standalone reliability."),
        ("4. Real-Time Movement Intelligence:", "FinCell's trajectory prediction engine processes velocity vectors and compass headings to anticipate high-probability destinations (e.g. Highways, Railway Stations, Airports), enabling fast interception.")
    ]

    for title, body in adv_text:
        story.append(Paragraph(f"<b>{title}</b> {body}", body_style))

    story.append(Spacer(1, 6))

    # Conclusion Box
    conc_text = (
        "<b>Summary Conclusion:</b> FinCell successfully merges Flutter's fluid cross-platform UI with "
        "Android Kotlin native background capabilities to deliver an anti-theft solution superior to standard OS-level trackers. "
        "It provides actionable forensic evidence, off-grid responsiveness, and proactive protection."
    )
    conc_table = Table([[Paragraph(conc_text, callout_style)]], colWidths=[532])
    conc_table.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, -1), colors.HexColor("#F1F5F9")),
        ('BORDER', (0, 0), (-1, -1), 1, colors.HexColor("#CBD5E1")),
        ('PADDING', (0, 0), (-1, -1), 7),
        ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
    ]))
    story.append(conc_table)

    doc.build(story, canvasmaker=NumberedCanvas)
    print(f"PDF successfully generated at: {filename}")

if __name__ == '__main__':
    out_file = os.path.join(os.getcwd(), "FinCell_Comprehensive_Project_Report.pdf")
    generate_report(out_file)
