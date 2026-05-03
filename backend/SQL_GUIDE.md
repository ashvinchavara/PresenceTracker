# Adtendo SQL Data Management Guide

You can now use the `backend/query.js` utility to run any SQL command directly on your database.

## How to run commands
Open your terminal in the project root and run:
`node backend/query.js "YOUR SQL COMMAND HERE"`

---

## 1. Viewing Data (Inspection)

### View all Personnel (Users)
`node backend/query.js "SELECT id, full_name, email FROM users"`

### View Organizational Structure (Departments & Branches)
`node backend/query.js "SELECT * FROM departments"`  
`node backend/query.js "SELECT * FROM sub_departments"`

### View Active Assignments (Who is assigned where)
`node backend/query.js "SELECT u.full_name, sd.name as branch, ua.role_name FROM user_assignments ua JOIN users u ON ua.user_id = u.id JOIN sub_departments sd ON ua.sub_department_id = sd.id"`

---

## 2. Managing Data (Updates & Cleanup)

### Change a User's Name
`node backend/query.js "UPDATE users SET full_name = 'New Name' WHERE id = 12"`

### Delete a specific Assignment (without deleting the user)
`node backend/query.js "DELETE FROM user_assignments WHERE id = [ASSIGNMENT_ID]"`

### Add a manual assignment
`node backend/query.js "INSERT INTO user_assignments (user_id, sub_department_id, role_name) VALUES (12, 5, 'Staff')"`

---

## 3. Database Schema Reference
To see the exact structure of any table:
`node backend/query.js "PRAGMA table_info(users)"`  
`node backend/query.js "PRAGMA table_info(user_assignments)"`
