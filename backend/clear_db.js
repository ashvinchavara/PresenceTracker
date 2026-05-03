const sqlite3 = require('sqlite3').verbose();
const db = new sqlite3.Database('./adtendo.db');
db.serialize(() => {
    db.run("DELETE FROM users");
    db.run("DELETE FROM user_assignments");
    db.run("DELETE FROM timetable_assignments");
    db.run("DELETE FROM attendance");
    console.log("Deleted all users, assignments, timetable, and attendance data successfully from adtendo.db.");
});
db.close();
