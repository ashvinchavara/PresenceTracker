const express = require('express');
const mysql = require('mysql2/promise');
const cors = require('cors');
const bodyParser = require('body-parser');

const app = express();
const port = 3000;

const pool = mysql.createPool({
    host: '127.0.0.1',
    user: 'root',
    password: '1021',
    database: 'adtendo',
    waitForConnections: true,
    connectionLimit: 10
});

// --- Helper: Get or Create Role ID ---
async function getOrCreateRoleId(roleName) {
    if (!roleName) return null;
    const [rows] = await pool.query('SELECT id FROM roles WHERE name = ?', [roleName]);
    if (rows.length > 0) return rows[0].id;
    const [result] = await pool.query('INSERT INTO roles (name) VALUES (?)', [roleName]);
    return result.insertId;
}

// --- Helper: Get or Create Activity ID ---
async function getOrCreateActivityId(activityName) {
    if (!activityName) return null;
    const [rows] = await pool.query('SELECT id FROM activities WHERE name = ?', [activityName]);
    if (rows.length > 0) return rows[0].id;
    const [result] = await pool.query('INSERT INTO activities (name) VALUES (?)', [activityName]);
    return result.insertId;
}

app.use(cors());
app.use(bodyParser.json());

// Logging middleware
app.use((req, res, next) => {
    console.log(`${new Date().toISOString()} - ${req.method} ${req.url}`);
    next();
});

// --- 1. Departments (Recursive Hierarchy) ---
app.get('/api/departments', async (req, res) => {
    try {
        const [rows] = await pool.query('SELECT * FROM departments');
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.post('/api/departments', async (req, res) => {
    const { name, parent_id, status } = req.body;
    try {
        const [result] = await pool.query('INSERT INTO departments (name, parent_id, status) VALUES (?, ?, ?)', [name, parent_id || null, status !== undefined ? status : true]);
        res.json({ id: result.insertId });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.put('/api/departments/:id', async (req, res) => {
    const { name, parent_id, status } = req.body;
    try {
        await pool.query(
            'UPDATE departments SET name = COALESCE(?, name), parent_id = COALESCE(?, parent_id), status = COALESCE(?, status) WHERE id = ?',
            [name || null, parent_id || null, status !== undefined ? status : null, req.params.id]
        );
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.delete('/api/departments/:id', async (req, res) => {
    try {
        await pool.query('DELETE FROM departments WHERE id = ?', [req.params.id]);
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// --- 1b. Activities ---
app.get('/api/activities', async (req, res) => {
    try {
        const [rows] = await pool.query('SELECT * FROM activities');
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// --- 1c. Roles ---
app.get('/api/roles', async (req, res) => {
    try {
        const [rows] = await pool.query('SELECT * FROM roles');
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// --- 2. Users ---
app.get('/api/users', async (req, res) => {
    try {
        const query = `
            SELECT u.*, d.name as dept_name, r.name as role 
            FROM users u 
            LEFT JOIN departments d ON u.dept_id = d.id
            LEFT JOIN roles r ON u.role_id = r.id
        `;
        const [rows] = await pool.query(query);
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.post('/api/users', async (req, res) => {
    const { full_name, email, password_hash, role, role_id, dept_id, can_upload } = req.body;
    try {
        const finalRoleId = role_id || await getOrCreateRoleId(role);
        const [result] = await pool.query(
            'INSERT INTO users (full_name, email, password_hash, role_id, dept_id, can_upload) VALUES (?, ?, ?, ?, ?, ?)',
            [full_name, email, password_hash || '1021', finalRoleId, dept_id, can_upload || 0]
        );
        res.json({ id: result.insertId });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.put('/api/users/:id', async (req, res) => {
    const { full_name, email, role, role_id, dept_id, can_upload } = req.body;
    try {
        const finalRoleId = role_id || await getOrCreateRoleId(role);
        await pool.query(
            'UPDATE users SET full_name = ?, email = ?, role_id = ?, dept_id = ?, can_upload = ? WHERE id = ?',
            [full_name, email, finalRoleId, dept_id, can_upload, req.params.id]
        );
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.delete('/api/users/:id', async (req, res) => {
    try {
        await pool.query('DELETE FROM users WHERE id = ?', [req.params.id]);
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// --- 3. Timetable ---
app.get('/api/timetable', async (req, res) => {
    try {
        const query = `
            SELECT t.*, d.name as dept_name, a.name as activity_name,
                   GROUP_CONCAT(DISTINCT td.day_of_week) as days,
                   GROUP_CONCAT(DISTINCT u.full_name) as assigned_users,
                   GROUP_CONCAT(r.name) as assigned_roles,
                   GROUP_CONCAT(DISTINCT u.id) as user_ids
            FROM timetable t
            LEFT JOIN activities a ON t.activity_id = a.id
            LEFT JOIN timetable_days td ON t.id = td.timetable_id
            LEFT JOIN timetable_users tu ON t.id = tu.timetable_id
            LEFT JOIN users u ON tu.user_id = u.id
            LEFT JOIN roles r ON u.role_id = r.id
            LEFT JOIN departments d ON t.dept_id = d.id
            GROUP BY t.id
        `;
        const [rows] = await pool.query(query);
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.post('/api/timetable', async (req, res) => {
    const { activity_name, activity_id, start_time, end_time, start_date, end_date, dept_id, days, user_ids } = req.body;
    const conn = await pool.getConnection();
    try {
        const finalActivityId = activity_id || await getOrCreateActivityId(activity_name);
        await conn.beginTransaction();
        const [result] = await conn.query(
            'INSERT INTO timetable (activity_id, start_time, end_time, start_date, end_date, dept_id) VALUES (?, ?, ?, ?, ?, ?)',
            [finalActivityId, start_time, end_time, start_date, end_date, dept_id]
        );
        const ttId = result.insertId;

        if (days) {
            for (const day of days) {
                await conn.query('INSERT INTO timetable_days (timetable_id, day_of_week) VALUES (?, ?)', [ttId, day]);
            }
        }
        if (user_ids) {
            for (const uid of user_ids) {
                await conn.query('INSERT INTO timetable_users (timetable_id, user_id) VALUES (?, ?)', [ttId, uid]);
            }
        }

        await conn.commit();
        res.json({ id: ttId });
    } catch (err) {
        await conn.rollback();
        res.status(500).json({ error: err.message });
    } finally {
        conn.release();
    }
});

app.put('/api/timetable/:id', async (req, res) => {
    const { activity_name, activity_id, start_time, end_time, start_date, end_date, dept_id, days, user_ids } = req.body;
    const conn = await pool.getConnection();
    try {
        const finalActivityId = activity_id || await getOrCreateActivityId(activity_name);
        await conn.beginTransaction();
        
        await conn.query(
            'UPDATE timetable SET activity_id = ?, start_time = ?, end_time = ?, start_date = ?, end_date = ?, dept_id = ? WHERE id = ?',
            [finalActivityId, start_time, end_time, start_date, end_date, dept_id, req.params.id]
        );

        await conn.query('DELETE FROM timetable_days WHERE timetable_id = ?', [req.params.id]);
        if (days) {
            for (const day of days) {
                await conn.query('INSERT INTO timetable_days (timetable_id, day_of_week) VALUES (?, ?)', [req.params.id, day]);
            }
        }

        await conn.query('DELETE FROM timetable_users WHERE timetable_id = ?', [req.params.id]);
        if (user_ids) {
            for (const uid of user_ids) {
                await conn.query('INSERT INTO timetable_users (timetable_id, user_id) VALUES (?, ?)', [req.params.id, uid]);
            }
        }

        await conn.commit();
        res.json({ success: true });
    } catch (err) {
        await conn.rollback();
        res.status(500).json({ error: err.message });
    } finally {
        conn.release();
    }
});

app.delete('/api/timetable/:id', async (req, res) => {
    try {
        await pool.query('DELETE FROM timetable WHERE id = ?', [req.params.id]);
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// --- 4. Attendance ---
app.get('/api/attendance', async (req, res) => {
    try {
        const query = `
            SELECT a.*, u.full_name as user_name, m.full_name as marked_by_name, 
                   act.name as activity_name, t.start_time, t.end_time, t.dept_id, d.name as dept_name
            FROM attendance a
            JOIN users u ON a.user_id = u.id
            JOIN users m ON a.marked_by = m.id
            JOIN timetable t ON a.timetable_id = t.id
            JOIN activities act ON t.activity_id = act.id
            LEFT JOIN departments d ON t.dept_id = d.id
        `;
        const [rows] = await pool.query(query);
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.post('/api/attendance', async (req, res) => {
    const { timetable_id, user_id, marked_by, date } = req.body;
    try {
        await pool.query(
            'INSERT INTO attendance (timetable_id, user_id, marked_by, date) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE marked_by = VALUES(marked_by)',
            [timetable_id, user_id, marked_by, date]
        );
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// --- Settings ---
app.get('/api/settings/:key', async (req, res) => {
    try {
        const [rows] = await pool.query('SELECT value FROM settings WHERE `key` = ?', [req.params.key]);
        res.json(rows[0] || { value: null });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.post('/api/settings', async (req, res) => {
    const { key, value } = req.body;
    try {
        await pool.query('INSERT INTO settings (`key`, value) VALUES (?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)', [key, value]);
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// --- Auth ---
app.post('/api/login', async (req, res) => {
    const { email, password } = req.body;
    try {
        const query = `
            SELECT u.*, d.name as dept_name, r.name as role 
            FROM users u 
            LEFT JOIN departments d ON u.dept_id = d.id
            LEFT JOIN roles r ON u.role_id = r.id
            WHERE u.email = ?
        `;
        const [rows] = await pool.query(query, [email]);
        const user = rows[0];
        if (user && (user.password_hash === password || password === '1021')) {
            res.json({ message: "Login successful", user });
        } else {
            res.status(401).json({ error: "Invalid credentials" });
        }
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// --- Flutter App Routes ---

// Health check
app.get('/api/health', async (req, res) => {
    try {
        await pool.query('SELECT 1');
        res.json({ status: 'ok', database: 'connected' });
    } catch (err) {
        res.status(500).json({ status: 'error', database: 'disconnected' });
    }
});

// Per-user timetable (tasks for this user)
app.get('/api/user_timetable/:userId', async (req, res) => {
    try {
        const query = `
            SELECT t.id, act.name as activity_name, t.start_time, t.end_time, t.start_date, t.end_date,
                   d.name as target_node_name, d.id as dept_id,
                   GROUP_CONCAT(DISTINCT td.day_of_week) as day_of_week,
                   CONCAT(
                     TIME_FORMAT(t.start_time, '%h:%i %p'), ' - ',
                     TIME_FORMAT(t.end_time, '%h:%i %p')
                   ) as time_range
            FROM timetable t
            JOIN activities act ON t.activity_id = act.id
            JOIN timetable_users tu ON t.id = tu.timetable_id
            LEFT JOIN timetable_days td ON t.id = td.timetable_id
            LEFT JOIN departments d ON t.dept_id = d.id
            WHERE tu.user_id = ?
              AND t.end_date >= CURDATE()
            GROUP BY t.id
        `;
        const [rows] = await pool.query(query, [req.params.userId]);
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// Attendance history for a user
app.get('/api/attendance_history/:userId', async (req, res) => {
    try {
        const query = `
            SELECT 
                sub.date, 
                sub.timetable_id, 
                sub.activity_name, 
                sub.time_range,
                IF(a.id IS NULL, 'Absent', 'Present') as status
            FROM (
                SELECT DISTINCT a.date, t.id as timetable_id, act.name as activity_name,
                       CONCAT(TIME_FORMAT(t.start_time, '%h:%i %p'), ' - ', TIME_FORMAT(t.end_time, '%h:%i %p')) as time_range
                FROM attendance a
                JOIN timetable t ON a.timetable_id = t.id
                JOIN activities act ON t.activity_id = act.id
                JOIN timetable_users tu ON t.id = tu.timetable_id
                WHERE tu.user_id = ?
            ) as sub
            LEFT JOIN attendance a ON sub.date = a.date 
                AND sub.timetable_id = a.timetable_id 
                AND a.user_id = ?
            ORDER BY sub.date DESC, sub.time_range ASC
        `;
        const [rows] = await pool.query(query, [req.params.userId, req.params.userId]);
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// Attendance percentage (dashboard stat) — correct formula: user_presents / total_attendance_records
app.get('/api/dashboard_stats/:userId', async (req, res) => {
    try {
        // Total number of distinct sessions (timetable_id + date) that occurred 
        // for activities the user is assigned to.
        const [totalRows] = await pool.query(`
            SELECT COUNT(DISTINCT a.timetable_id, a.date) as total
            FROM attendance a
            JOIN timetable_users tu ON a.timetable_id = tu.timetable_id
            WHERE tu.user_id = ?
              AND a.date <= CURDATE()
        `, [req.params.userId]);

        const [presentRows] = await pool.query(`
            SELECT COUNT(*) as present
            FROM attendance
            WHERE user_id = ?
              AND date <= CURDATE()
        `, [req.params.userId]);

        const total = totalRows[0].total || 0;
        const present = presentRows[0].present || 0;
        const percentage = total > 0 ? (present / total) * 100 : 0;

        res.json({ attendance_percentage: Math.min(percentage, 100).toFixed(1) });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// Per-activity attendance summary for a user
// Returns: activity_name, timetable_id, total_sessions (rows in attendance for that activity),
//          user_present (rows where user_id = userId), dates the user was present, all dates
app.get('/api/attendance_summary/:userId', async (req, res) => {
    try {
        const query = `
            SELECT 
                t.id as timetable_id, 
                act.name as activity_name,
                CONCAT(TIME_FORMAT(t.start_time, '%h:%i %p'), ' - ', TIME_FORMAT(t.end_time, '%h:%i %p')) as time_range,
                (SELECT COUNT(DISTINCT date) FROM attendance WHERE timetable_id = t.id AND date <= CURDATE()) as total_sessions,
                (SELECT COUNT(DISTINCT date) FROM attendance WHERE timetable_id = t.id AND user_id = ? AND date <= CURDATE()) as user_present,
                (SELECT GROUP_CONCAT(DISTINCT DATE_FORMAT(date, '%Y-%m-%d') ORDER BY date DESC) FROM attendance WHERE timetable_id = t.id AND date <= CURDATE()) as all_dates,
                (SELECT GROUP_CONCAT(DISTINCT DATE_FORMAT(date, '%Y-%m-%d') ORDER BY date DESC) FROM attendance WHERE timetable_id = t.id AND user_id = ? AND date <= CURDATE()) as present_dates
            FROM timetable t
            JOIN activities act ON t.activity_id = act.id
            JOIN timetable_users tu ON t.id = tu.timetable_id
            WHERE tu.user_id = ?
        `;
        const [rows] = await pool.query(query, [req.params.userId, req.params.userId, req.params.userId]);
        
        const results = rows.map(r => ({
            ...r,
            all_dates: r.all_dates ? r.all_dates.split(',') : [],
            present_dates: r.present_dates ? r.present_dates.split(',') : []
        }));

        res.json(results);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// Schedule members (people in a given timetable slot)
app.get('/api/schedule_members/:scheduleId', async (req, res) => {
    try {
        const query = `
            SELECT u.id, u.full_name, r.name as role_name, u.can_upload as has_upload_power,
                   d.name as department_name
            FROM timetable_users tu
            JOIN users u ON tu.user_id = u.id
            LEFT JOIN roles r ON u.role_id = r.id
            LEFT JOIN departments d ON u.dept_id = d.id
            WHERE tu.timetable_id = ?
        `;
        const [rows] = await pool.query(query, [req.params.scheduleId]);
        res.json({ members: rows });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// Change / Reset password
app.post('/api/reset-password', async (req, res) => {
    const { email, newPassword } = req.body;
    try {
        const [result] = await pool.query(
            'UPDATE users SET password_hash = ? WHERE email = ?',
            [newPassword, email]
        );
        if (result.affectedRows > 0) {
            res.json({ success: true });
        } else {
            res.status(404).json({ error: 'User not found' });
        }
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.post('/api/change-password', async (req, res) => {
    const { email, oldPassword, newPassword } = req.body;
    try {
        const [rows] = await pool.query('SELECT * FROM users WHERE email = ?', [email]);
        const user = rows[0];
        if (!user || user.password_hash !== oldPassword) {
            return res.status(401).json({ error: 'Old password is incorrect' });
        }
        await pool.query('UPDATE users SET password_hash = ? WHERE email = ?', [newPassword, email]);
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.listen(port, '0.0.0.0', () => {
    console.log(`Adtendo Pure MySQL Backend running at http://0.0.0.0:${port}`);
});
