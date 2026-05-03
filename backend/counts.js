const sqlite3 = require('sqlite3').verbose();
const db = new sqlite3.Database('backend/adtendo.db');

db.serialize(() => {
    db.get('SELECT COUNT(*) as c FROM user_assignments', [], (err, row) => console.log('User Assignments:', row.c));
    db.get('SELECT COUNT(*) as c FROM timetable_assignments', [], (err, row) => console.log('Timetable Assignments:', row.c));
    db.get('SELECT COUNT(*) as c FROM attendance', [], (err, row) => console.log('Attendance Records:', row.c));
    db.get('SELECT COUNT(*) as c FROM users', [], (err, row) => console.log('Users:', row.c));
    db.close();
});
