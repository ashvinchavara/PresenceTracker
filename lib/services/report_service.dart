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

  static pw.Widget _buildActivitySection(Map<String, dynamic> activity) {
    final activityName = activity['activity_name'] ?? 'Unknown Activity';
    final dynamic sessionsData = activity['sessions'];
    
    List<Map<String, dynamic>> sessions = [];
    if (sessionsData != null && sessionsData is List) {
      sessions = sessionsData.map((s) => Map<String, dynamic>.from(s)).toList();
    }

    if (sessions.isEmpty) {
      // Fallback to all_dates/present_dates if sessions is missing
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

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
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
          spacing: 5,
          runSpacing: 5,
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
            
            return pw.Container(
              width: 100,
              padding: const pw.EdgeInsets.all(5),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey300),
                color: isPresent ? PdfColors.green50 : PdfColors.red50,
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    DateFormat('MMM d, yyyy').format(date),
                    style: pw.TextStyle(
                      fontSize: 8,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    isPresent ? 'PRESENT' : 'ABSENT',
                    style: pw.TextStyle(
                      fontSize: 8,
                      color: isPresent ? PdfColors.green : PdfColors.red,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  if (timeRange.toString().isNotEmpty)
                    pw.Text(
                      timeRange.toString(),
                      style: const pw.TextStyle(
                        fontSize: 7,
                        color: PdfColors.grey600,
                      ),
                    ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
