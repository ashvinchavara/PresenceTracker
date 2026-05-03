// app.js - Direct MySQL Connection Logic
let API_BASE = 'http://localhost:3000/api';

// Shared State
let state = {
    departments: [], // Recursive Tree
    users: [],
    timetable: [],
    attendance: [],
    sort: {
        column: 'full_name',
        direction: 'asc'
    }
};

let selectedPickerUsers = []; // For Timetable Assignment

function convertTo24h(timeStr, ampm) {
    if (!timeStr || !timeStr.includes(':')) return '00:00:00';
    let [hours, minutes] = timeStr.split(':');
    hours = parseInt(hours);
    if (ampm === 'PM' && hours < 12) hours += 12;
    if (ampm === 'AM' && hours === 12) hours = 0;
    return `${hours.toString().padStart(2, '0')}:${minutes.padStart(2, '0')}:00`;
}

function parse24h(time24) {
    if (!time24) return { time: '12:00', ampm: 'AM' };
    let [hours, minutes] = time24.split(':');
    hours = parseInt(hours);
    const ampm = hours >= 12 ? 'PM' : 'AM';
    hours = hours % 12;
    hours = hours ? hours : 12;
    return {
        time: `${hours.toString().padStart(2, '0')}:${minutes}`,
        ampm: ampm
    };
}

function convertTo24h(timeStr, ampm) {
    if (!timeStr || !timeStr.includes(':')) return '00:00:00';
    let [hours, minutes] = timeStr.split(':');
    hours = parseInt(hours);
    if (ampm === 'PM' && hours < 12) hours += 12;
    if (ampm === 'AM' && hours === 12) hours = 0;
    return `${hours.toString().padStart(2, '0')}:${minutes.padStart(2, '0')}:00`;
}

function parse24h(time24) {
    if (!time24) return { time: '12:00', ampm: 'AM' };
    let [hours, minutes] = time24.split(':');
    hours = parseInt(hours);
    const ampm = hours >= 12 ? 'PM' : 'AM';
    hours = hours % 12;
    hours = hours ? hours : 12;
    return {
        time: `${hours.toString().padStart(2, '0')}:${minutes}`,
        ampm: ampm
    };
}

// --- Initialization ---

document.addEventListener('DOMContentLoaded', () => {
    initApp();
});

async function initApp() {
    setupEventListeners();
    await loadAllData();
}

async function loadAllData() {
    const statusIndicator = document.getElementById('db-status');
    const connectionText = document.getElementById('connection-text');

    const [depts, users, tt, att] = await Promise.all([
        apiFetch('/departments'),
        apiFetch('/users'),
        apiFetch('/timetable'),
        apiFetch('/attendance')
    ]);

    if (depts) {
        state.departments = depts;
        state.users = users;
        state.timetable = tt;
        state.attendance = att;

        statusIndicator.classList.add('connected');
        connectionText.innerText = 'Connected (MySQL Direct)';
        renderUI();
    } else {
        connectionText.innerText = 'Offline / Error';
    }
}

function renderUI() {
    renderOverview();
    renderUserAssignments();
    renderTimetable();
    renderAttendanceLogs();
    renderUploadPermissions();
    populateSelectors();
}

// --- API Helpers ---

async function apiFetch(endpoint) {
    try {
        const response = await fetch(`${API_BASE}${endpoint}`);
        return await response.json();
    } catch (e) {
        console.error(`Fetch failed: ${e.message}`);
        return null;
    }
}

async function apiPost(endpoint, data) {
    try {
        const response = await fetch(`${API_BASE}${endpoint}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data)
        });
        return await response.json();
    } catch (e) {
        console.error(`Post failed: ${e.message}`);
    }
}

// --- 1. Overview (Departments) ---

function renderOverview() {
    const tableBody = document.getElementById('deps-table-body');
    if (!tableBody) return;
    tableBody.innerHTML = '';

    // Filter root departments (parent_id is null)
    const roots = state.departments.filter(d => !d.parent_id);

    roots.forEach(dept => {
        const isActive = dept.status !== 0 && dept.status !== false && dept.status !== null;
        tableBody.innerHTML += `
            <tr class="${isActive ? '' : 'inactive-dept'}">
                <td onclick="openNodeExplorer(${dept.id})" style="cursor: pointer;">
                    <strong style="color: var(--primary);">${dept.name}</strong>
                    <br>
                </td>
                <td>
                    <span class="badge ${isActive ? 'success' : 'danger'}" 
                          onclick="event.stopPropagation(); toggleDeptStatus(${dept.id}, ${isActive})" 
                          style="cursor: pointer;">
                        ${isActive ? 'Active' : 'Inactive'}
                    </span>
                </td>
            </tr>
        `;
    });
}

window.toggleDeptStatus = async (id, currentStatus) => {
    const newStatus = currentStatus ? 0 : 1;

    // 1. Update the target department
    await fetch(`${API_BASE}/departments/${id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: newStatus })
    });

    // 2. If deactivating, strictly deactivate all descendants
    if (newStatus === 0) {
        const descendants = getAllDescendantIds(id);
        for (const childId of descendants) {
            await fetch(`${API_BASE}/departments/${childId}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ status: 0 })
            });
        }
    }

    await loadAllData();

    // If modal is open for this ID, refresh it
    const modal = document.getElementById('details-modal');
    if (modal && modal.style.display === 'flex') {
        openNodeExplorer(id);
    }
};

function getAllDescendantIds(parentId) {
    let ids = [];
    const children = state.departments.filter(d => d.parent_id === parentId);
    children.forEach(child => {
        ids.push(child.id);
        ids = ids.concat(getAllDescendantIds(child.id));
    });
    return ids;
}

function isAncestorInactive(deptId) {
    if (!deptId) return false;
    let current = state.departments.find(d => d.id === deptId);
    while (current && current.parent_id) {
        let parent = state.departments.find(d => d.id === current.parent_id);
        if (parent && !parent.status) return true;
        current = parent;
    }
    return false;
}

function getAncestors(id) {
    const path = [];
    if (!id) return path;

    // Add root entry
    path.push({ name: 'Global Root', id: null });

    let current = state.departments.find(d => d.id === id);
    let ancestors = [];
    while (current && current.parent_id) {
        let parent = state.departments.find(d => d.id === current.parent_id);
        if (parent) ancestors.unshift(parent);
        current = parent;
    }
    return path.concat(ancestors);
}

function getFullDeptPath(deptId) {
    if (!deptId) return 'Unassigned';
    const ancestors = getAncestors(deptId);
    const current = state.departments.find(d => d.id === deptId);
    const pathParts = ancestors
        .filter(a => a.id !== null) // Skip 'Global Root'
        .map(a => a.name);
    if (current) pathParts.push(current.name);
    return pathParts.join(' <span style="opacity: 0.3; margin: 0 4px;">&rsaquo;</span> ');
}

window.openNodeExplorer = (id) => {
    let dept = state.departments.find(d => d.id === id);

    // If no ID, show root explorer
    if (!dept) {
        dept = { name: 'Infrastructure Root', id: null, status: 1, parent_id: null };
    }

    const deptUsers = state.users.filter(u => u.dept_id === id);
    const deptSchedules = state.timetable.filter(t => t.dept_id === id);
    const subDepts = state.departments.filter(d => d.parent_id === id);

    // Update Modal Rail
    const ancestors = getAncestors(id);
    const rail = document.getElementById('modal-ancestors');
    const stack = document.getElementById('ancestor-stack');

    if (ancestors.length > 0) {
        rail.style.display = 'block';
        stack.innerHTML = `
            <ul class="nav-links">
                ${ancestors.map(anc => `
                    <li onclick="openNodeExplorer(${anc.id})" style="gap: 10px; padding: 10px 14px;">
                        <span class="material-symbols-rounded" style="font-size: 18px; opacity: 0.6;">subdirectory_arrow_right</span>
                        <span style="font-size: 13px;">${anc.name}</span>
                    </li>
                `).join('')}
            </ul>
        `;
    } else {
        rail.style.display = 'none';
    }

    document.getElementById('modal-title').innerText = dept.name;
    document.getElementById('modal-subtitle').innerText = id ? 'Department Infrastructure Node' : 'Global Infrastructure Overview';

    const modalList = document.getElementById('modal-list');
    modalList.innerHTML = `
        <div style="padding: 40px; display: flex; flex-direction: column; align-items: center; gap: 30px;">
            <!-- Picker-style Header with Actions -->
            <div class="custom-input dropdown-trigger" style="width: 800px; padding: 20px 30px; cursor: default; display: flex; justify-content: space-between; align-items: center; background: rgba(99, 102, 241, 0.1); border: 1px solid var(--primary); border-radius: 20px;">
                <div style="display: flex; flex-direction: column;">
                    <span class="text-muted" style="font-size: 11px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 4px;">Active Context</span>
                    <span style="font-size: 18px; font-weight: 700; color: var(--text-main);">${dept.name}</span>
                </div>
                
                <div style="display: flex; align-items: center; gap: 15px;">
                    <div style="display: flex; gap: 8px; background: rgba(0,0,0,0.2); padding: 6px; border-radius: 12px; border: 1px solid var(--glass-border);">
                        <button class="btn-icon-small" onclick="addNewSubDept(${id})" title="Add Sub-Node">
                            <span class="material-symbols-rounded" style="color: var(--success); font-size: 18px;">add_box</span>
                        </button>
                        ${id ? `
                            <button class="btn-icon-small" onclick="editDeptName(${id}, '${dept.name}')" title="Edit Node">
                                <span class="material-symbols-rounded" style="color: var(--warning); font-size: 18px;">edit</span>
                            </button>
                            <button class="btn-icon-small" 
                                ${deptUsers.length === 0 && deptSchedules.length === 0 && subDepts.length === 0 ? `onclick="deleteDept(${id})"` : 'disabled'} 
                                title="${deptUsers.length === 0 && deptSchedules.length === 0 && subDepts.length === 0 ? 'Delete Node' : 'Cannot delete: Node contains personnel, sub-nodes, or active schedules'}"
                                style="${deptUsers.length === 0 && deptSchedules.length === 0 && subDepts.length === 0 ? '' : 'opacity: 0.3; cursor: not-allowed; filter: grayscale(1);'}">
                                <span class="material-symbols-rounded" style="color: var(--danger); font-size: 18px;">delete</span>
                            </button>
                        ` : ''}
                    </div>
                    <span class="badge ${dept.status ? 'success' : 'danger'}" 
                          ${isAncestorInactive(id) ? '' : `onclick="toggleDeptStatus(${id}, ${dept.status})"`} 
                          style="cursor: ${isAncestorInactive(id) ? 'not-allowed' : 'pointer'}; opacity: ${isAncestorInactive(id) && !dept.status ? '0.5' : '1'};"
                          title="${isAncestorInactive(id) ? 'Status locked: Parent node is inactive' : 'Click to toggle status (Cascades to sub-nodes if deactivating)'}">
                        ${dept.status ? 'Active' : 'Inactive'}
                    </span>
                </div>
            </div>

            <div class="glass-panel" style="width: 800px; padding: 40px;">
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 40px;">
                    <div>
                        <h3 style="margin-bottom: 20px; font-size: 14px; color: var(--text-muted); text-transform: uppercase; border-bottom: 1px solid var(--glass-border); padding-bottom: 10px;">Node Intelligence</h3>
                        
                        <div style="display: flex; flex-direction: column; gap: 15px;">
                            <div class="clickable-stat" onclick="showDeptUsers(${id})" style="cursor: pointer; padding: 15px; background: rgba(255,255,255,0.03); border-radius: 12px; border: 1px solid var(--glass-border); transition: all 0.2s;">
                                <div style="display: flex; justify-content: space-between; align-items: center;">
                                    <div>
                                        <span style="display: block; font-size: 24px; font-weight: 700; color: var(--primary);">${deptUsers.length}</span>
                                        <span style="font-size: 12px; color: var(--text-muted); text-transform: uppercase;">Personnel Assigned</span>
                                    </div>
                                    <span class="material-symbols-rounded" style="color: var(--primary); opacity: 0.5;">group</span>
                                </div>
                            </div>

                            <div class="clickable-stat" onclick="showDeptSchedules(${id})" style="cursor: pointer; padding: 15px; background: rgba(255,255,255,0.03); border-radius: 12px; border: 1px solid var(--glass-border); transition: all 0.2s;">
                                <div style="display: flex; justify-content: space-between; align-items: center;">
                                    <div>
                                        <span style="display: block; font-size: 24px; font-weight: 700; color: var(--accent-blue);">${deptSchedules.length}</span>
                                        <span style="font-size: 12px; color: var(--text-muted); text-transform: uppercase;">Active Schedules</span>
                                    </div>
                                    <span class="material-symbols-rounded" style="color: var(--accent-blue); opacity: 0.5;">calendar_today</span>
                                </div>
                            </div>
                        </div>
                    </div>
                    
                    <div id="modal-content-area">
                        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; border-bottom: 1px solid var(--glass-border); padding-bottom: 10px;">
                            <h3 style="font-size: 14px; color: var(--text-muted); text-transform: uppercase; margin: 0;">
                                ${id ? 'Sub-Nodes' : 'Infrastructure Branches'}
                            </h3>
                        </div>
                        <div id="modal-child-tree" class="custom-scrollbar" style="max-height: 400px; overflow: auto; padding: 20px; background: rgba(0,0,0,0.2); border-radius: 12px; border: 1px solid var(--glass-border);">
                            ${buildTreeHTML(id, 'explorer') || '<p class="text-muted" style="text-align: center; padding: 20px;">No further sub-nodes in this branch.</p>'}
                        </div>
                    </div>
                </div>
            </div>
        </div>
    `;

    document.getElementById('details-modal').style.display = 'flex';
};

window.showDeptUsers = (id) => {
    const users = state.users.filter(u => u.dept_id === id);
    const area = document.getElementById('modal-content-area');

    area.innerHTML = `
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; border-bottom: 1px solid var(--glass-border); padding-bottom: 10px;">
            <h3 style="font-size: 14px; color: var(--text-muted); text-transform: uppercase; margin: 0;">Personnel List</h3>
        </div>
        <div class="custom-scrollbar" style="max-height: 400px; overflow: auto; padding: 10px; background: rgba(0,0,0,0.2); border-radius: 12px; border: 1px solid var(--glass-border);">
            ${users.length ? users.map(u => `
                <div style="display: flex; justify-content: space-between; align-items: center; padding: 12px; border-bottom: 1px solid rgba(255,255,255,0.05);">
                    <div>
                        <div style="font-weight: 600; font-size: 14px;">${u.full_name}</div>
                        <div style="font-size: 11px; color: var(--text-muted);">${u.role}</div>
                    </div>
                    ${u.can_upload ? '<span class="badge success" style="font-size: 9px; padding: 2px 8px;">Upload Power</span>' : ''}
                </div>
            `).join('') : '<p class="text-muted" style="text-align: center; padding: 20px;">No personnel assigned.</p>'}
        </div>
    `;
};

window.showDeptSchedules = (id) => {
    const schedules = state.timetable.filter(t => t.dept_id === id);
    const area = document.getElementById('modal-content-area');

    area.innerHTML = `
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; border-bottom: 1px solid var(--glass-border); padding-bottom: 10px;">
            <h3 style="font-size: 14px; color: var(--text-muted); text-transform: uppercase; margin: 0;">Operational Schedules</h3>
        </div>
        <div class="custom-scrollbar" style="max-height: 400px; overflow: auto; padding: 10px; background: rgba(0,0,0,0.2); border-radius: 12px; border: 1px solid var(--glass-border);">
            ${schedules.length ? schedules.map(s => `
                <div style="padding: 12px; border-bottom: 1px solid rgba(255,255,255,0.05);">
                    <div style="font-weight: 600; font-size: 14px; color: var(--accent-blue);">${s.activity_name}</div>
                    <div style="font-size: 11px; color: var(--text-muted); margin-top: 4px;">
                        ${s.days} | ${s.start_time.slice(0, 5)} - ${s.end_time.slice(0, 5)}
                    </div>
                </div>
            `).join('') : '<p class="text-muted" style="text-align: center; padding: 20px;">No schedules active.</p>'}
        </div>
    `;
};

window.resetModalView = (id) => {
    const area = document.getElementById('modal-content-area');
    area.innerHTML = `
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; border-bottom: 1px solid var(--glass-border); padding-bottom: 10px;">
            <h3 style="font-size: 14px; color: var(--text-muted); text-transform: uppercase; margin: 0;">
                ${id ? 'Sub-Nodes' : 'Infrastructure Branches'}
            </h3>
        </div>
        <div id="modal-child-tree" class="custom-scrollbar" style="max-height: 400px; overflow: auto; padding: 20px; background: rgba(0,0,0,0.2); border-radius: 12px; border: 1px solid var(--glass-border);">
            ${buildTreeHTML(id, 'explorer') || '<p class="text-muted" style="text-align: center; padding: 20px;">No further sub-nodes in this branch.</p>'}
        </div>
    `;
};

window.addNewSubDept = async (parentId) => {
    const name = prompt('Enter name for the new sub-department:');
    if (!name) return;
    await apiPost('/departments', { name, parent_id: parentId });
    await loadAllData();
    openNodeExplorer(parentId);
};

window.editDeptName = async (id, oldName) => {
    const name = prompt('Enter new name for department:', oldName);
    if (!name || name === oldName) return;
    await fetch(`${API_BASE}/departments/${id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name })
    });
    await loadAllData();
    openNodeExplorer(id);
};

document.getElementById('btn-close-modal').onclick = () => {
    document.getElementById('details-modal').style.display = 'none';
};

window.deleteDept = async (id) => {
    if (!confirm('Delete this department and all nested levels?')) return;
    await fetch(`${API_BASE}/departments/${id}`, { method: 'DELETE' });
    loadAllData();
};

// --- 2. Users & Assignments ---

function renderUserAssignments() {
    const tableBody = document.getElementById('assignments-table-body');
    const filter = document.getElementById('assignment-name-filter')?.value.toLowerCase() || '';
    tableBody.innerHTML = '';

    let sortedUsers = [...state.users];

    // Apply Filter
    sortedUsers = sortedUsers.filter(u =>
        u.full_name.toLowerCase().includes(filter) ||
        (u.email && u.email.toLowerCase().includes(filter)) ||
        (u.dept_name && u.dept_name.toLowerCase().includes(filter))
    );

    // Apply Sort
    if (state.sort.column) {
        sortedUsers.sort((a, b) => {
            let valA = a[state.sort.column] || '';
            let valB = b[state.sort.column] || '';

            // Map common aliases from HTML
            if (state.sort.column === 'sub_dept_name') { valA = a.dept_name || ''; valB = b.dept_name || ''; }
            if (state.sort.column === 'role_name') { valA = a.role || ''; valB = b.role || ''; }

            if (typeof valA === 'string') valA = valA.toLowerCase();
            if (typeof valB === 'string') valB = valB.toLowerCase();

            if (valA < valB) return state.sort.direction === 'asc' ? -1 : 1;
            if (valA > valB) return state.sort.direction === 'asc' ? 1 : -1;
            return 0;
        });
    }

    if (sortedUsers.length === 0) {
        tableBody.innerHTML = '<tr><td colspan="5" class="loading-text">No matching personnel found.</td></tr>';
        return;
    }

    sortedUsers.forEach(u => {
        tableBody.innerHTML += `
            <tr id="user-row-${u.id}">
                <td style="text-align: center;">
                    <input type="checkbox" class="user-select-checkbox" data-id="${u.id}" onchange="updateBulkDeleteUI()">
                </td>
                <td><strong>${u.full_name}</strong><br><small>${u.email}</small></td>
                <td style="font-size: 13px;">${getFullDeptPath(u.dept_id)}</td>
                <td><span class="badge warning">${u.role || 'student'}</span></td>
                <td class="action-cell">
                    <button class="btn-icon" onclick="editUserRow(${u.id})">
                        <span class="material-symbols-rounded">edit</span>
                    </button>
                    <button class="btn-icon text-danger" onclick="deleteUser(${u.id})">
                        <span class="material-symbols-rounded">delete</span>
                    </button>
                </td>
            </tr>
        `;
    });

    updateSortIcons();
    updateBulkDeleteUI();
}

window.sortAssignments = (column) => {
    if (state.sort.column === column) {
        state.sort.direction = state.sort.direction === 'asc' ? 'desc' : 'asc';
    } else {
        state.sort.column = column;
        state.sort.direction = 'asc';
    }
    renderUserAssignments();
};

window.editUserRow = (id) => {
    const u = state.users.find(user => user.id === id);
    const row = document.getElementById(`user-row-${id}`);
    if (!u || !row) return;

    row.innerHTML = `
        <td style="text-align: center;"><input type="checkbox" disabled></td>
        <td>
            <input type="text" id="edit-name-${id}" class="custom-input" value="${u.full_name}" 
                style="font-size: 13px; height: 32px; margin-bottom: 5px; width: 100%;">
            <input type="email" id="edit-email-${id}" class="custom-input" value="${u.email}" 
                style="font-size: 11px; height: 28px; width: 100%;">
        </td>
        <td>
            <select id="edit-dept-${id}" class="custom-input" style="font-size: 12px; height: 40px; width: 100%;">
                <option value="">Unassigned</option>
                ${state.departments.map(d => {
        const path = getFullDeptPath(d.id).replace(/<[^>]*>?/gm, ''); // Strip HTML tags
        return `<option value="${d.id}" ${d.id === u.dept_id ? 'selected' : ''}>${path}</option>`;
    }).join('')}
            </select>
        </td>
        <td>
            <input type="text" id="edit-role-${id}" class="custom-input" value="${u.role || ''}" 
                style="font-size: 13px; height: 40px; width: 100%;">
        </td>
        <td class="action-cell">
            <button class="btn-icon text-success" onclick="saveUserEdit(${id})">
                <span class="material-symbols-rounded">check</span>
            </button>
            <button class="btn-icon" onclick="renderUserAssignments()">
                <span class="material-symbols-rounded">close</span>
            </button>
        </td>
    `;
};

window.saveUserEdit = async (id) => {
    const full_name = document.getElementById(`edit-name-${id}`).value;
    const email = document.getElementById(`edit-email-${id}`).value;
    const dept_id = document.getElementById(`edit-dept-${id}`).value || null;
    const role = document.getElementById(`edit-role-${id}`).value;

    const u = state.users.find(user => user.id === id);

    await fetch(`${API_BASE}/users/${id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            full_name,
            email,
            dept_id,
            role,
            can_upload: u ? u.can_upload : 0
        })
    });

    loadAllData();
};

function updateSortIcons() {
    const columns = ['sub_dept_name', 'role_name'];
    columns.forEach(col => {
        const iconId = col === 'sub_dept_name' ? 'sort-icon-node' : 'sort-icon-role';
        const icon = document.getElementById(iconId);
        if (!icon) return;

        if (state.sort.column === col) {
            icon.innerText = state.sort.direction === 'asc' ? 'expand_less' : 'expand_more';
            icon.style.opacity = '1';
            icon.style.color = 'var(--primary)';
        } else {
            icon.innerText = 'unfold_more';
            icon.style.opacity = '0.3';
            icon.style.color = 'inherit';
        }
    });
}

window.toggleAllAssignments = (checked) => {
    const checkboxes = document.querySelectorAll('.user-select-checkbox');
    checkboxes.forEach(cb => cb.checked = checked);
    updateBulkDeleteUI();
};

window.updateBulkDeleteUI = () => {
    const checkboxes = document.querySelectorAll('.user-select-checkbox');
    const selectedCount = Array.from(checkboxes).filter(cb => cb.checked).length;
    const btn = document.getElementById('btn-bulk-delete-assignments');
    const countDisplay = document.getElementById('bulk-delete-count');
    const selectAllCb = document.getElementById('assignment-select-all');

    if (btn && countDisplay) {
        btn.style.display = selectedCount > 0 ? 'flex' : 'none';
        countDisplay.innerText = selectedCount;
    }

    if (selectAllCb) {
        selectAllCb.checked = selectedCount > 0 && selectedCount === checkboxes.length;
        selectAllCb.indeterminate = selectedCount > 0 && selectedCount < checkboxes.length;
    }
};

window.deleteSelectedAssignments = async () => {
    const checkboxes = document.querySelectorAll('.user-select-checkbox:checked');
    const ids = Array.from(checkboxes).map(cb => cb.dataset.id);

    if (ids.length === 0) return;
    if (!confirm(`Delete ${ids.length} selected users?`)) return;

    for (const id of ids) {
        await fetch(`${API_BASE}/users/${id}`, { method: 'DELETE' });
    }

    loadAllData();
};

window.deleteUser = async (id) => {
    if (!confirm('Delete this user?')) return;
    await fetch(`${API_BASE}/users/${id}`, { method: 'DELETE' });
    loadAllData();
};

// --- 3. Timetable ---

function formatTime12h(timeStr) {
    if (!timeStr) return '';
    let [hours, minutes] = timeStr.split(':');
    hours = parseInt(hours);
    const ampm = hours >= 12 ? 'PM' : 'AM';
    hours = hours % 12;
    hours = hours ? hours : 12; // the hour '0' should be '12'
    return `${hours}:${minutes} ${ampm}`;
}

function renderTimetable() {
    const tableBody = document.getElementById('tt-table-body');
    tableBody.innerHTML = '';

    if (!state.timetable) return;

    state.timetable.forEach(t => {
        let rolesHtml = '<span class="text-muted">No users</span>';
        if (t.assigned_roles) {
            const roleCounts = {};
            t.assigned_roles.split(',').forEach(role => {
                if (role && role !== 'null') {
                    roleCounts[role] = (roleCounts[role] || 0) + 1;
                }
            });
            rolesHtml = `<div style="display: flex; flex-direction: column; gap: 4px; align-items: flex-start;">` + 
                Object.entries(roleCounts).map(([role, count]) => `
                    <div class="role-group-badge" style="display: inline-flex; align-items: center; background: rgba(255, 255, 255, 0.05); border: 1px solid rgba(255, 255, 255, 0.1); border-radius: 12px; padding: 3px 10px; font-size: 11px;">
                        <span style="margin-right: 8px; opacity: 0.9;">${role}</span>
                        <span style="background: #0078D4; color: white; border-radius: 50%; min-width: 18px; height: 18px; display: flex; align-items: center; justify-content: center; font-size: 10px; font-weight: bold;">${count}</span>
                    </div>
                `).join('') + `</div>`;
        }

        tableBody.innerHTML += `
            <tr id="tt-row-${t.id}">
                <td><span class="badge info">${t.days || 'N/A'}</span></td>
                <td style="max-width: 250px; white-space: normal;">${rolesHtml}</td>
                <td><small>${getFullDeptPath(t.dept_id)}</small></td>
                <td><strong>${t.activity_name}</strong></td>
                <td>
                    <div style="font-size: 13px;">${formatTime12h(t.start_time.slice(0, 5))} - ${formatTime12h(t.end_time.slice(0, 5))}</div>
                    <div class="text-muted" style="font-size: 11px;">${new Date(t.start_date).toLocaleDateString()} to ${new Date(t.end_date).toLocaleDateString()}</div>
                </td>
                <td class="action-cell">
                    <button class="btn-icon" onclick="editTimetableRow(${t.id})">
                        <span class="material-symbols-rounded">edit</span>
                    </button>
                    <button class="btn-icon text-danger" onclick="deleteTimetable(${t.id})">
                        <span class="material-symbols-rounded">delete</span>
                    </button>
                </td>
            </tr>
        `;
    });
}

window.deleteTimetable = async (id) => {
    if (!confirm('Delete this schedule entry?')) return;
    await fetch(`${API_BASE}/timetable/${id}`, { method: 'DELETE' });
    loadAllData();
};

window.editTimetableRow = (id) => {
    const t = state.timetable.find(item => item.id === id);
    const row = document.getElementById(`tt-row-${id}`);
    if (!t || !row) return;

    // Load existing users into picker state for this edit
    selectedPickerUsers = t.user_ids ? t.user_ids.split(',').map(uid => parseInt(uid)) : [];

    row.innerHTML = `
        <td>
            <select id="edit-tt-day-${id}" class="custom-input" style="font-size: 11px; height: 32px;">
                <option value="Monday" ${t.days === 'Monday' ? 'selected' : ''}>Mon</option>
                <option value="Tuesday" ${t.days === 'Tuesday' ? 'selected' : ''}>Tue</option>
                <option value="Wednesday" ${t.days === 'Wednesday' ? 'selected' : ''}>Wed</option>
                <option value="Thursday" ${t.days === 'Thursday' ? 'selected' : ''}>Thu</option>
                <option value="Friday" ${t.days === 'Friday' ? 'selected' : ''}>Fri</option>
                <option value="Saturday" ${t.days === 'Saturday' ? 'selected' : ''}>Sat</option>
                <option value="Sunday" ${t.days === 'Sunday' ? 'selected' : ''}>Sun</option>
            </select>
        </td>
        <td>
            <button class="btn-primary" style="font-size: 10px; padding: 5px 10px;" onclick="openPersonnelPicker()">
                Manage (${selectedPickerUsers.length})
            </button>
        </td>
        <td>
            <select id="edit-tt-dept-${id}" class="custom-input" style="font-size: 11px; height: 32px;">
                ${state.departments.map(d => `<option value="${d.id}" ${d.id === t.dept_id ? 'selected' : ''}>${d.name}</option>`).join('')}
            </select>
        </td>
        <td>
            <input type="text" id="edit-tt-name-${id}" class="custom-input" value="${t.activity_name}" style="font-size: 12px; height: 32px;">
        </td>
        <td>
            <div style="display: flex; flex-direction: column; gap: 4px;">
                <div style="display: flex; gap: 4px;">
                    <input type="text" id="edit-tt-start-val-${id}" class="custom-input" value="${parse24h(t.start_time).time}" style="font-size: 11px; height: 28px; width: 50px; padding: 4px;">
                    <select id="edit-tt-start-ampm-${id}" class="custom-input" style="font-size: 10px; height: 28px; width: 45px;">
                        <option value="AM" ${parse24h(t.start_time).ampm === 'AM' ? 'selected' : ''}>AM</option>
                        <option value="PM" ${parse24h(t.start_time).ampm === 'PM' ? 'selected' : ''}>PM</option>
                    </select>
                    <span style="opacity: 0.5; align-self: center;">-</span>
                    <input type="text" id="edit-tt-end-val-${id}" class="custom-input" value="${parse24h(t.end_time).time}" style="font-size: 11px; height: 28px; width: 50px; padding: 4px;">
                    <select id="edit-tt-end-ampm-${id}" class="custom-input" style="font-size: 10px; height: 28px; width: 45px;">
                        <option value="AM" ${parse24h(t.end_time).ampm === 'AM' ? 'selected' : ''}>AM</option>
                        <option value="PM" ${parse24h(t.end_time).ampm === 'PM' ? 'selected' : ''}>PM</option>
                    </select>
                </div>
                <div style="display: flex; gap: 4px;">
                    <input type="date" id="edit-tt-sdate-${id}" class="custom-input" value="${t.start_date.slice(0, 10)}" style="font-size: 10px; height: 24px; padding: 2px;">
                    <input type="date" id="edit-tt-edate-${id}" class="custom-input" value="${t.end_date.slice(0, 10)}" style="font-size: 10px; height: 24px; padding: 2px;">
                </div>
            </div>
        </td>
        <td class="action-cell">
            <button class="btn-icon text-success" onclick="saveTimetableEdit(${id})">
                <span class="material-symbols-rounded">check</span>
            </button>
            <button class="btn-icon" onclick="renderTimetable()">
                <span class="material-symbols-rounded">close</span>
            </button>
        </td>
    `;
};

window.saveTimetableEdit = async (id) => {
    const payload = {
        activity_name: document.getElementById(`edit-tt-name-${id}`).value,
        start_time: convertTo24h(document.getElementById(`edit-tt-start-val-${id}`).value, document.getElementById(`edit-tt-start-ampm-${id}`).value),
        end_time: convertTo24h(document.getElementById(`edit-tt-end-val-${id}`).value, document.getElementById(`edit-tt-end-ampm-${id}`).value),
        start_date: document.getElementById(`edit-tt-sdate-${id}`).value,
        end_date: document.getElementById(`edit-tt-edate-${id}`).value,
        dept_id: document.getElementById(`edit-tt-dept-${id}`).value,
        days: [document.getElementById(`edit-tt-day-${id}`).value],
        user_ids: selectedPickerUsers
    };

    await fetch(`${API_BASE}/timetable/${id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    });
    
    selectedPickerUsers = [];
    loadAllData();
};

window.openPersonnelPicker = () => {
    // Populate Role filter
    const roles = [...new Set(state.users.map(u => u.role).filter(r => r))];
    const roleSelect = document.getElementById('picker-filter-role');
    if (roleSelect) {
        roleSelect.innerHTML = '<option value="">All Roles</option>' + roles.map(r => `<option value="${r}">${r}</option>`).join('');
    }

    // Populate Dept filter
    const deptSelect = document.getElementById('picker-filter-dept');
    if (deptSelect) {
        deptSelect.innerHTML = '<option value="">All Departments</option>' + state.departments.map(d => `<option value="${d.id}">${d.name}</option>`).join('');
    }

    // Attach filter events
    ['picker-search-name', 'picker-filter-role', 'picker-filter-dept'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.oninput = renderPersonnelPicker;
    });

    renderPersonnelPicker();
    document.getElementById('personnel-picker-modal').style.display = 'flex';
};

function renderPersonnelPicker() {
    const search = document.getElementById('picker-search-name').value.toLowerCase();
    const role = document.getElementById('picker-filter-role').value;
    const dept = document.getElementById('picker-filter-dept').value;

    const list = document.getElementById('picker-user-list');
    list.innerHTML = '';

    const filtered = state.users.filter(u => {
        const matchesSearch = u.full_name.toLowerCase().includes(search) || (u.email && u.email.toLowerCase().includes(search));
        const matchesRole = !role || u.role === role;
        const matchesDept = !dept || u.dept_id == dept;
        return matchesSearch && matchesRole && matchesDept;
    });

    const countDisplay = document.getElementById('picker-count-display');
    if (countDisplay) countDisplay.innerText = `${filtered.length} users found`;

    const selectAllBtn = document.getElementById('btn-picker-select-all');
    if (selectAllBtn) {
        const allSelected = filtered.length > 0 && filtered.every(u => selectedPickerUsers.includes(u.id));
        selectAllBtn.innerText = allSelected ? 'Deselect All' : 'Select All';
    }

    if (filtered.length === 0) {
        list.innerHTML = '<div class="p-20 text-muted" style="text-align: center;">No matching staff found.</div>';
    }

    filtered.forEach(u => {
        const isSelected = selectedPickerUsers.includes(u.id);
        list.innerHTML += `
            <div class="personnel-item" style="display: flex; align-items: center; gap: 15px; padding: 12px; border-bottom: 1px solid rgba(255,255,255,0.05);">
                <input type="checkbox" class="picker-checkbox" value="${u.id}" ${isSelected ? 'checked' : ''} 
                    onchange="togglePickerUser(${u.id}, this.checked)"
                    style="width: 18px; height: 18px; cursor: pointer;">
                <div style="flex: 1;">
                    <div style="font-weight: 500; font-size: 14px;">${u.full_name}</div>
                    <div class="text-muted" style="font-size: 11px;">${getFullDeptPath(u.dept_id)} • ${u.role || 'No Role'}</div>
                </div>
            </div>
        `;
    });
}

window.togglePickerUser = (id, checked) => {
    if (checked) {
        if (!selectedPickerUsers.includes(id)) selectedPickerUsers.push(id);
    } else {
        selectedPickerUsers = selectedPickerUsers.filter(uid => uid !== id);
    }
};

// --- 4. Attendance Logs ---

function renderAttendanceLogs() {
    const tableBody = document.getElementById('logs-table-body');
    if (!tableBody) return;
    tableBody.innerHTML = '';

    if (!state.attendance || state.attendance.length === 0) {
        tableBody.innerHTML = '<tr><td colspan="6" class="loading-text">No verification logs available.</td></tr>';
        return;
    }

    state.attendance.forEach(log => {
        tableBody.innerHTML += `
            <tr>
                <td>
                    <strong>${log.user_name}</strong>
                </td>
                <td><small>${getFullDeptPath(log.dept_id)}</small></td>
                <td>
                    <div style="font-size: 13px;">${formatTime12h(log.start_time.slice(0, 5))} - ${formatTime12h(log.end_time.slice(0, 5))}</div>
                </td>
                <td><strong>${log.activity_name}</strong></td>
                <td><span class="badge success">Verified</span></td>
                <td class="text-right">
                    <div style="font-size: 12px; font-weight: 500;">Device Sync</div>
                    <div class="text-muted" style="font-size: 10px;">by ${log.marked_by_name}</div>
                </td>
            </tr>
        `;
    });
}

function renderUploadPermissions() {
    const rolesContainer = document.getElementById('roles-checkbox-container');
    const usersContainer = document.getElementById('users-selected-container');
    const panel = document.getElementById('upload-permissions-panel');
    const navTab = document.getElementById('nav-attendance-logs');
    if (!rolesContainer || !usersContainer) return;

    // Roles
    const roles = [...new Set(state.users.map(u => u.role).filter(r => r))];
    const roleAuths = roles.map(role => {
        const usersInRole = state.users.filter(u => u.role === role);
        return usersInRole.every(u => u.can_upload);
    });
    
    rolesContainer.innerHTML = roles.map((role, idx) => {
        return `
            <div style="display: flex; align-items: center; gap: 10px; margin-bottom: 10px;">
                <input type="checkbox" onchange="toggleRoleUploadPermission('${role}', this.checked)" ${roleAuths[idx] ? 'checked' : ''}>
                <span style="font-size: 13px;">${role}</span>
            </div>
        `;
    }).join('');

    // Users
    const authUsers = state.users.filter(u => u.can_upload);
    usersContainer.innerHTML = authUsers.length ? authUsers.map(u => `
        <div class="badge" style="background: var(--primary); padding: 8px 12px; display: flex; align-items: center; gap: 8px;">
            <span style="font-size: 11px;">${u.full_name}</span>
            <span class="material-symbols-rounded" onclick="toggleUserUploadPermission(${u.id}, false)" style="font-size: 14px; cursor: pointer;">close</span>
        </div>
    `).join('') : '<div class="text-muted" style="font-size: 12px; text-align: center; width: 100%; padding-top: 30px;">No specific users authorized</div>';

    // Blink Logic
    const hasAnyAuth = authUsers.length > 0 || roleAuths.some(a => a);
    if (!hasAnyAuth) {
        panel?.classList.add('blink-alert');
        navTab?.classList.add('blink-alert');
    } else {
        panel?.classList.remove('blink-alert');
        navTab?.classList.remove('blink-alert');
    }
}

window.toggleUserUploadPermission = async (userId, status) => {
    const u = state.users.find(user => user.id === userId);
    if (!u) return;

    await fetch(`${API_BASE}/users/${userId}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ 
            ...u, 
            can_upload: status ? 1 : 0 
        })
    });
    loadAllData();
};

window.toggleRoleUploadPermission = async (role, status) => {
    const usersInRole = state.users.filter(u => u.role === role);
    for (const u of usersInRole) {
        await fetch(`${API_BASE}/users/${u.id}`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ...u, can_upload: status ? 1 : 0 })
        });
    }
    loadAllData();
};

// --- Selectors & Interaction ---

function populateSelectors() {
    const assignTree = document.getElementById('assign-subdept-tree');
    if (assignTree) {
        assignTree.innerHTML = buildTreeHTML(null, 'assign');
    }

    const ttTree = document.getElementById('tt-subdept-tree');
    if (ttTree) {
        ttTree.innerHTML = buildTreeHTML(null, 'tt');
    }
}

function buildTreeHTML(parentId, context = 'assign') {
    // Filter logic: if parentId is null/undefined, find roots (!d.parent_id). Otherwise match exactly.
    const children = state.departments.filter(d => {
        if (parentId === null || parentId === undefined || parentId === '') {
            return !d.parent_id;
        }
        return d.parent_id == parentId;
    });

    if (children.length === 0) return '';

    let html = '<ul>';
    children.forEach(child => {
        html += `
            <li onclick="event.stopPropagation(); selectNode(${child.id}, '${child.name}', '${context}')" class="${child.status ? '' : 'inactive-dept'}">
                <div style="display: flex; align-items: center; gap: 8px;">
                    <span>${child.name}</span>
                    ${!child.status ? '<span class="material-symbols-rounded" style="font-size: 14px; color: var(--danger);">close</span>' : ''}
                </div>
                ${buildTreeHTML(child.id, context)}
            </li>
        `;
    });
    html += '</ul>';
    return html;
}

window.selectNode = (id, name, context = 'assign') => {
    if (context === 'explorer') {
        openNodeExplorer(id);
        return;
    }

    const prefix = context === 'tt' ? 'tt' : 'assign';
    document.getElementById(`${prefix}-subdept-select`).value = id;
    document.getElementById(`${prefix}-subdept-display`).innerText = name;
    document.getElementById(`${prefix}-subdept-display`).classList.remove('text-muted');
    document.getElementById(`${prefix}-subdept-dropdown`).style.display = 'none';
};

function setupEventListeners() {
    // Tab switching
    document.querySelectorAll('.nav-links li').forEach(li => {
        li.onclick = () => {
            document.querySelectorAll('.nav-links li').forEach(l => l.classList.remove('active'));
            document.querySelectorAll('.content-section').forEach(s => s.classList.remove('active'));
            li.classList.add('active');
            document.getElementById(li.dataset.tab).classList.add('active');
        };
    });

    // Dropdown triggers
    ['assign', 'tt'].forEach(prefix => {
        const trigger = document.getElementById(`${prefix}-subdept-trigger`);
        if (trigger) {
            trigger.onclick = () => {
                const dd = document.getElementById(`${prefix}-subdept-dropdown`);
                dd.style.display = dd.style.display === 'none' ? 'block' : 'none';
            };
        }
    });

    // Add Department
    document.getElementById('overview-btn-add-dept').onclick = async () => {
        const name = document.getElementById('overview-new-dept').value;
        if (!name) return;
        await apiPost('/departments', { name });
        document.getElementById('overview-new-dept').value = '';
        loadAllData();
    };

    // Bulk Deploy
    document.getElementById('btn-bulk-deploy').onclick = async () => {
        const deptId = document.getElementById('assign-subdept-select').value;
        const role = document.getElementById('assign-role-input').value;
        const data = document.getElementById('bulk-personnel-data').value;

        if (!deptId || !data) return alert('Please select a department and enter user data.');

        const lines = data.split('\n');
        for (const line of lines) {
            const [name, email] = line.split(',').map(s => s.trim());
            if (name && email) {
                await apiPost('/users', { full_name: name, email, role, dept_id: deptId });
            }
        }
        loadAllData();
    };

    // Refresh
    document.getElementById('refresh-btn').onclick = () => loadAllData();

    // Assignment Filter
    const filterInput = document.getElementById('assignment-name-filter');
    if (filterInput) {
        filterInput.oninput = () => renderUserAssignments();
    }

    // --- Timetable Events ---

    // Open Picker
    const btnOpenPicker = document.getElementById('btn-open-personnel-picker');
    if (btnOpenPicker) {
        btnOpenPicker.onclick = () => openPersonnelPicker();
    }

    // Close Picker
    const btnClosePicker = document.getElementById('btn-close-picker');
    if (btnClosePicker) {
        btnClosePicker.onclick = () => {
            document.getElementById('personnel-picker-modal').style.display = 'none';
        };
    }

    // Select All in Picker
    const btnPickerSelectAll = document.getElementById('btn-picker-select-all');
    if (btnPickerSelectAll) {
        btnPickerSelectAll.onclick = () => {
            const search = document.getElementById('picker-search-name').value.toLowerCase();
            const role = document.getElementById('picker-filter-role').value;
            const dept = document.getElementById('picker-filter-dept').value;

            const filtered = state.users.filter(u => {
                const matchesSearch = u.full_name.toLowerCase().includes(search) || (u.email && u.email.toLowerCase().includes(search));
                const matchesRole = !role || u.role === role;
                const matchesDept = !dept || u.dept_id == dept;
                return matchesSearch && matchesRole && matchesDept;
            });

            const allSelected = filtered.length > 0 && filtered.every(u => selectedPickerUsers.includes(u.id));

            if (allSelected) {
                const filteredIds = filtered.map(u => u.id);
                selectedPickerUsers = selectedPickerUsers.filter(id => !filteredIds.includes(id));
            } else {
                filtered.forEach(u => {
                    if (!selectedPickerUsers.includes(u.id)) selectedPickerUsers.push(u.id);
                });
            }
            renderPersonnelPicker();
        };
    }

    // Confirm Picker
    const btnConfirmPicker = document.getElementById('btn-confirm-picker');
    if (btnConfirmPicker) {
        btnConfirmPicker.onclick = async () => {
            if (window.pickerContext === 'permissions') {
                // Bulk update users
                for (const u of state.users) {
                    const shouldHavePerm = selectedPickerUsers.includes(u.id);
                    const currentPerm = u.can_upload ? 1 : 0;
                    if (currentPerm != (shouldHavePerm ? 1 : 0)) {
                        await fetch(`${API_BASE}/users/${u.id}`, {
                            method: 'PUT',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ ...u, can_upload: shouldHavePerm ? 1 : 0 })
                        });
                    }
                }
                window.pickerContext = null;
                loadAllData();
                document.getElementById('personnel-picker-modal').style.display = 'none';
                return;
            }

            const countDisplay = document.getElementById('selected-user-count');
            countDisplay.innerText = `${selectedPickerUsers.length} Selected`;
            countDisplay.style.display = selectedPickerUsers.length > 0 ? 'inline-block' : 'none';

            // Update any active "Manage" button in the table
            const activeManageBtn = document.querySelector('tr[id^="tt-row-"] button[onclick="openPersonnelPicker()"]');
            if (activeManageBtn) {
                activeManageBtn.innerText = `Manage (${selectedPickerUsers.length})`;
            }

            document.getElementById('personnel-picker-modal').style.display = 'none';
        };
    }

    // Add Timetable
    const btnAddTT = document.getElementById('btn-add-tt');
    if (btnAddTT) {
        btnAddTT.onclick = async () => {
            const deptId = document.getElementById('tt-subdept-select').value;
            const opName = document.getElementById('tt-operation-name').value;
            const startTimeVal = document.getElementById('tt-start-time').value;
            const startAmpm = document.getElementById('tt-start-ampm').value;
            const endTimeVal = document.getElementById('tt-end-time').value;
            const endAmpm = document.getElementById('tt-end-ampm').value;
            const startDate = document.getElementById('tt-start-date').value;
            const endDate = document.getElementById('tt-end-date').value;
            const day = document.getElementById('tt-day-select').value;

            if (!deptId || !opName || !startTimeVal || !endTimeVal || !startDate || !endDate) {
                return alert('Please fill in all operational parameters.');
            }

            if (selectedPickerUsers.length === 0) {
                return alert('Please assign at least one personnel to this operation.');
            }

            const payload = {
                activity_name: opName,
                start_time: convertTo24h(startTimeVal, startAmpm),
                end_time: convertTo24h(endTimeVal, endAmpm),
                start_date: startDate,
                end_date: endDate,
                dept_id: deptId,
                days: [day],
                user_ids: selectedPickerUsers
            };

            await apiPost('/timetable', payload);

            // Reset Form
            selectedPickerUsers = [];
            document.getElementById('selected-user-count').style.display = 'none';
            document.getElementById('tt-operation-name').value = '';

            loadAllData();
            alert('Operation committed to master schedule.');
        };
    }

    // --- Attendance Permissions Events ---
    const btnOpenPermPicker = document.getElementById('btn-open-user-permissions-picker');
    if (btnOpenPermPicker) {
        btnOpenPermPicker.onclick = () => {
            window.pickerContext = 'permissions';
            selectedPickerUsers = state.users.filter(u => u.can_upload).map(u => u.id);
            window.openPersonnelPicker();
        };
    }
}
