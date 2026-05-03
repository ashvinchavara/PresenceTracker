# Presence Tracker (Adtendo)

A modern, hierarchical attendance and scheduling system with a 3NF MySQL backend and a Flutter BLE Mesh attendance mechanism.

## 🚀 Features

- **Infinite Hierarchy**: Recursive department structure (College -> Course -> Year -> Class).
- **Smart Scheduling**: 3NF normalized timetable system with recurring days and user assignments.
- **BLE Mesh Attendance**: Proximity-based attendance using Bluetooth Low Energy Mesh (Teacher as Root, Students as Leaf nodes).
- **Premium Admin Dashboard**: Vanilla JS/CSS dashboard for infrastructure management.
- **Cross-Platform App**: Flutter-based client app for schedules and presence verification.

## 🛠️ Technology Stack

- **Frontend**: Flutter (Mobile/Web), Vanilla JS/HTML/CSS (Admin)
- **Backend**: Node.js, Express.js
- **Database**: MySQL (3NF)
- **Proximity**: Bluetooth Low Energy (Mesh Protocol)

## 📋 Getting Started

### Backend Setup
1. Navigate to `/backend`
2. Run `npm install`
3. Configure MySQL connection in `server.js`
4. Run `npm start`

### Admin Dashboard
1. Open `admin_dashboard/index.html` in a browser.

### Flutter App
1. Ensure Flutter is in your PATH.
2. Run `flutter pub get`
3. Run `flutter run`

---
*Developed as a premium attendance solution.*
