const mysql = require('mysql2/promise');

const config = {
    host: '127.0.0.1',
    user: 'root',
    password: '1021',
    database: 'adtendo',
    multipleStatements: true
};

async function run() {
    let connection;
    try {
        connection = await mysql.createConnection(config);
        console.log('Connected to Local MySQL.');

        // 1. Add Unique Constraint
        try {
            console.log('Adding unique constraint...');
            await connection.query('ALTER TABLE attendance ADD CONSTRAINT unique_attendance UNIQUE(timetable_id, user_id, date)');
            console.log('✅ Unique constraint added.');
        } catch (err) {
            console.log('ℹ️ Constraint status:', err.message);
        }

        // 2. Create Procedure
        console.log('Creating stored procedure...');
        await connection.query('DROP PROCEDURE IF EXISTS generate_attendance');
        
        const createProc = `
        CREATE PROCEDURE generate_attendance()
        BEGIN
            DECLARE done INT DEFAULT FALSE;
            DECLARE v_timetable_id INT;
            DECLARE v_start_time TIME;
            DECLARE v_end_time TIME;
            DECLARE v_start_date DATE;
            DECLARE v_end_date DATE;
            DECLARE v_day VARCHAR(20);
            DECLARE v_curr_date DATE;

            DECLARE cur CURSOR FOR
                SELECT t.id,
                       t.start_time,
                       t.end_time,
                       t.start_date,
                       LEAST(t.end_date, '2026-05-15'),
                       td.day_of_week
                FROM timetable t
                JOIN timetable_days td
                    ON td.timetable_id = t.id;

            DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

            OPEN cur;

            timetable_loop: LOOP
                FETCH cur INTO
                    v_timetable_id,
                    v_start_time,
                    v_end_time,
                    v_start_date,
                    v_end_date,
                    v_day;

                IF done THEN
                    LEAVE timetable_loop;
                END IF;

                SET v_curr_date = v_start_date;

                WHILE v_curr_date <= v_end_date DO
                    IF DAYNAME(v_curr_date) = v_day THEN
                        INSERT INTO attendance
                        (
                            timetable_id,
                            user_id,
                            marked_by,
                            date,
                            entry_time,
                            exit_time
                        )
                        SELECT
                            v_timetable_id,
                            tu.user_id,
                            (
                                SELECT id
                                FROM users
                                WHERE can_upload = 1
                                ORDER BY RAND()
                                LIMIT 1
                            ) AS marked_by,
                            v_curr_date,
                            ADDTIME(
                                v_start_time,
                                SEC_TO_TIME(FLOOR(RAND() * 900))
                            ) AS entry_time,
                            SUBTIME(
                                v_end_time,
                                SEC_TO_TIME(FLOOR(RAND() * 900))
                            ) AS exit_time
                        FROM timetable_users tu
                        WHERE tu.timetable_id = v_timetable_id
                        AND RAND() < 0.82
                        ON DUPLICATE KEY UPDATE entry_time = VALUES(entry_time);
                    END IF;
                    SET v_curr_date = DATE_ADD(v_curr_date, INTERVAL 1 DAY);
                END WHILE;
            END LOOP;

            CLOSE cur;
        END`;

        await connection.query(createProc);
        console.log('✅ Stored procedure created.');

        // 3. Call Procedure
        console.log('Calling generate_attendance()...');
        await connection.query('CALL generate_attendance()');
        console.log('✅ Attendance data generated successfully.');

    } catch (err) {
        console.error('❌ SQL Execution Error:', err.message);
    } finally {
        if (connection) await connection.end();
    }
}

run();
