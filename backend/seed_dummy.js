const sqlite3 = require('sqlite3').verbose();
const path = require('path');

const dbPath = path.resolve(__dirname, 'adtendo.db');
const db = new sqlite3.Database(dbPath);

db.serialize(() => {
    // 1. Add Department
    db.run("INSERT INTO departments (name) VALUES ('Engineering')");
    db.run("INSERT INTO departments (name) VALUES ('Medical')");

    // 2. Add Sub-Departments
    db.run("INSERT INTO sub_departments (name, department_id) VALUES ('BCA', 1)");
    db.run("INSERT INTO sub_departments (name, department_id) VALUES ('Nursing', 2)");

    // 3. Add Users
    db.run("INSERT INTO users (full_name, email, phone, designation) VALUES ('Dr. Smith', 'smith@med.com', '123456', 'Senior Doctor')");
    db.run("INSERT INTO users (full_name, email, phone, designation) VALUES ('John Doe', 'john@eng.com', '654321', 'Lecturer')");

    // 4. Assignments
    db.run("INSERT INTO user_assignments (user_id, sub_department_id, role_id) VALUES (1, 2, 3)"); // Smith in Nursing as Doctor
    db.run("INSERT INTO user_assignments (user_id, sub_department_id, role_id) VALUES (2, 1, 1)"); // Doe in BCA as Teacher

    // 5. Activities
    db.run("INSERT INTO activities (name) VALUES ('Software Engineering')");
    db.run("INSERT INTO activities (name) VALUES ('Emergency Care')");

    // 6. Timetable
    db.run("INSERT INTO timetable_assignments (user_assignment_id, slot_id, activity_id, day_of_week) VALUES (1, 1, 2, 'Monday')");
    db.run("INSERT INTO timetable_assignments (user_assignment_id, slot_id, activity_id, day_of_week) VALUES (2, 2, 1, 'Tuesday')");

    // 7. Attendance
    db.run("INSERT INTO attendance (timetable_assignment_id, date, status, present_count) VALUES (1, '2026-03-12', 'Present', 20)");
    db.run("INSERT INTO attendance (timetable_assignment_id, date, status, present_count) VALUES (2, '2026-03-12', 'Present', 45)");

    console.log('Dummy SQL records populated successfully.');
    db.close();
});
