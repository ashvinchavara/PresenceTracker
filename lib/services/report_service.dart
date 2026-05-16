import 'dart:io';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';

class ReportService {
  static Future<void> generateIndividualReport({
    required String userName,
    required String userRole,
    required List<Map<String, dynamic>> summary,
  }) async {
    final pdf = pw.Document();

    final now = DateTime.now();
    final formattedDate = DateFormat('MMM d, yyyy h:mm a').format(now);

    // Calculate Overall Stats
    int totalOverallSessions = 0;
    int totalOverallPresent = 0;
    for (final activity in summary) {
      totalOverallSessions += (activity['total_sessions'] as num? ?? 0).toInt();
      totalOverallPresent += (activity['user_present'] as num? ?? 0).toInt();
    }
    double overallPercentage = totalOverallSessions > 0 
        ? (totalOverallPresent / totalOverallSessions) * 100 
        : 0.0;

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(30),
        build: (pw.Context context) {
          return [
            // Header
            pw.Text(
              'Individual Attendance Dashboard',
              style: pw.TextStyle(
                fontSize: 22,
                fontWeight: pw.FontWeight.bold,
                color: PdfColor.fromHex('#0078D4'),
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Text(
              'Personnel: $userName | Role: $userRole',
              style: const pw.TextStyle(
                fontSize: 11,
                color: PdfColors.grey700,
              ),
            ),
            pw.Text(
              'Overall Attendance: ${overallPercentage.toStringAsFixed(1)}% ($totalOverallPresent/$totalOverallSessions)',
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.blueGrey900,
              ),
            ),
            pw.Text(
              'Generated: $formattedDate',
              style: const pw.TextStyle(
                fontSize: 11,
                color: PdfColors.grey700,
              ),
            ),
            pw.SizedBox(height: 20),

            // Activities
            for (final activity in summary) ...[
              _buildActivitySection(activity),
              pw.SizedBox(height: 20),
            ],
          ];
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
      name: 'Attendance_Report_${userName.replaceAll(' ', '_')}.pdf',
    );
  }

  static String _formatTime12h(dynamic timeStr) {
    if (timeStr == null || timeStr.toString().isEmpty || timeStr == '--:--') return '--:--';
    try {
      final parts = timeStr.toString().split(':');
      if (parts.length < 2) return timeStr.toString();
      int hour = int.parse(parts[0]);
      int minute = int.parse(parts[1]);
      final ampm = hour >= 12 ? 'PM' : 'AM';
      hour = hour % 12;
      if (hour == 0) hour = 12;
      return "${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} $ampm";
    } catch (e) {
      return timeStr.toString();
    }
  }

  static pw.Widget _buildActivitySection(Map<String, dynamic> activity) {
    final activityName = activity['activity_name'] ?? 'Unknown Activity';
    final dynamic sessionsData = activity['sessions'];
    
    List<Map<String, dynamic>> sessions = [];
    if (sessionsData != null && sessionsData is List) {
      sessions = sessionsData.map((s) => Map<String, dynamic>.from(s)).toList();
    }

    if (sessions.isEmpty) {
      final List<dynamic> allDates = activity['all_dates'] ?? [];
      final List<dynamic> presentDates = activity['present_dates'] ?? [];
      if (allDates.isNotEmpty) {
        sessions = allDates.map((d) => {
          'date': d.toString(),
          'is_present': presentDates.contains(d),
          'time_range': ''
        }).toList();
      }
    }

    if (sessions.isEmpty) return pw.SizedBox();

    final int total = (activity['total_sessions'] as num? ?? sessions.length).toInt();
    final int present = (activity['user_present'] as num? ?? sessions.where((s) => s['is_present'] == true).length).toInt();
    final double percentage = total > 0 ? (present / total) * 100 : 0.0;

    // Use pw.Wrap to ensure the header and grid stay on the same page (Wrap doesn't break)
    return pw.Wrap(
      children: [
        pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          // Activity Header
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: const pw.BoxDecoration(
              color: PdfColors.grey100,
            ),
            width: double.infinity,
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  activityName,
                  style: pw.TextStyle(
                    fontSize: 12,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blueGrey900,
                  ),
                ),
                pw.Text(
                  '${percentage.toStringAsFixed(1)}% ($present/$total)',
                  style: pw.TextStyle(
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blueGrey700,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 10),

          // Grid of sessions
          pw.Wrap(
            spacing: 4,
            runSpacing: 4,
            children: sessions.map((session) {
              final dateStr = session['date'] ?? '';
              if (dateStr.isEmpty) return pw.SizedBox();

              DateTime date;
              try {
                 date = DateTime.parse(dateStr);
              } catch (e) {
                 return pw.SizedBox();
              }

              final isPresent = session['is_present'] == true || session['is_present'] == 1;
              final timeRange = session['time_range'] ?? '';
              
              // Entry/Exit Formatting
              final entryTime = _formatTime12h(session['entry_time']);
              final exitTime = _formatTime12h(session['exit_time']);
              final displayTime = (isPresent && entryTime != '--:--') 
                  ? "$entryTime - $exitTime" 
                  : timeRange.toString();

              return pw.Container(
                width: 78, // Reduced from 100 to fit more items
                padding: const pw.EdgeInsets.all(4),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
                  color: isPresent ? PdfColors.green50 : PdfColors.red50,
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      DateFormat('MMM d, yyyy').format(date),
                      style: pw.TextStyle(
                        fontSize: 7,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      isPresent ? 'PRESENT' : 'ABSENT',
                      style: pw.TextStyle(
                        fontSize: 7,
                        color: isPresent ? PdfColors.green : PdfColors.red,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    if (displayTime.isNotEmpty)
                      pw.Text(
                        displayTime,
                        style: const pw.TextStyle(
                          fontSize: 6,
                          color: PdfColors.grey600,
                        ),
                      ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    ],
  );
}
}
