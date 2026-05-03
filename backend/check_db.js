const sqlite3 = require('sqlite3').verbose();
const db = new sqlite3.Database('adtendo.db');

db.all("SELECT * FROM timetable_assignments", [], (err, rows) => {
    if (err) console.error(err);
    console.log("--- Timetable Assignments ---");
    console.log(JSON.stringify(rows || [], null, 2));

    db.all("SELECT * FROM user_assignments", [], (err2, rows2) => {
        if (err2) console.error(err2);
        console.log("--- User Assignments ---");
        console.log(JSON.stringify(rows2 || [], null, 2));
        db.close();
    });
});
