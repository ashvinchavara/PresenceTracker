const sqlite3 = require('sqlite3').verbose();
const path = require('path');

const dbPath = path.resolve(__dirname, 'adtendo.db');
const db = new sqlite3.Database(dbPath);

const schema = `
-- 1. Departments Hierarchy
CREATE TABLE IF NOT EXISTS departments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    status TEXT DEFAULT 'Active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sub_departments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    department_id INTEGER NOT NULL,
    parent_id INTEGER, -- Allows nesting
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (department_id) REFERENCES departments(id) ON DELETE CASCADE,
    FOREIGN KEY (parent_id) REFERENCES sub_departments(id) ON DELETE CASCADE
);

-- 2. Users & Assignments
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    full_name TEXT NOT NULL,
    email TEXT UNIQUE,
    phone TEXT,
    designation TEXT,
    password_hash TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS user_assignments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    sub_department_id INTEGER NOT NULL,
    role_name TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (sub_department_id) REFERENCES sub_departments(id) ON DELETE CASCADE
);

-- 3. Timetable & Activities
CREATE TABLE IF NOT EXISTS activities (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    description TEXT
);

CREATE TABLE IF NOT EXISTS timetable_assignments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_assignment_id INTEGER,
    activity_id INTEGER NOT NULL,
    day_of_week TEXT NOT NULL,
    time_range TEXT NOT NULL,
    temp_user_name TEXT,
    target_role_name TEXT,
    target_sub_dept_id INTEGER,
    FOREIGN KEY (user_assignment_id) REFERENCES user_assignments(id) ON DELETE CASCADE,
    FOREIGN KEY (activity_id) REFERENCES activities(id) ON DELETE CASCADE,
    FOREIGN KEY (target_sub_dept_id) REFERENCES sub_departments(id) ON DELETE CASCADE
);

-- 4. Attendance
CREATE TABLE IF NOT EXISTS attendance (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timetable_assignment_id INTEGER NOT NULL,
    date TEXT NOT NULL,
    status TEXT DEFAULT 'Present',
    present_count INTEGER DEFAULT 0,
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    entry_time TEXT,
    exit_time TEXT,
    FOREIGN KEY (timetable_assignment_id) REFERENCES timetable_assignments(id) ON DELETE CASCADE
);
`;

db.serialize(() => {
    db.exec(schema, (err) => {
        if (err) {
            console.error('Error creating database:', err.message);
        } else {
            console.log('Database and tables updated successfully.');
            // No longer seeding fixed roles or slots
        }
        db.close();
    });
});
