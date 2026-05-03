const sqlite3 = require('sqlite3').verbose();
const db = new sqlite3.Database('backend/adtendo.db');

db.serialize(() => {
    db.get('SELECT * FROM users WHERE id = 12', [], (err, user) => {
        console.log('User:', user);
        db.all('SELECT * FROM user_assignments WHERE user_id = 12', [], (err, assignments) => {
            console.log('Assignments:', assignments);
            if (assignments && assignments.length > 0) {
                const ids = assignments.map(a => a.id);
                db.all(`SELECT * FROM timetable_assignments WHERE user_assignment_id IN (${ids.join(',')})`, [], (err, timetable) => {
                    console.log('Timetable:', timetable);
                    db.close();
                });
            } else {
                console.log('No assignments found.');
                db.close();
            }
        });
    });
});
