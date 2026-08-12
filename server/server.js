const { WebSocketServer } = require('ws');
const admin = require('firebase-admin');
const https = require('https');
const serviceAccount = require('./catchme-e8d0f-firebase-adminsdk-fbsvc-c70772cf2d.json');

// ── Flag --debug ──────────────────────────────────────────────────────────────
// Avvia con: node server.js --debug
// Abilita il logging di coordinate GPS, token push e distanze tra utenti.
// In produzione questi dati NON vengono mai stampati.
const isDebug = process.argv.includes('--debug');

/** Stampa solo se il server è avviato con --debug */
function debugLog(...args) {
    if (isDebug) console.log(...args);
}

if (isDebug) {
    console.log('[INIT] Modalità DEBUG attiva: coordinate GPS, token push e distanze saranno visibili nei log.');
} else {
    console.log('[INIT] Modalità produzione: log sensibili disabilitati. Usa --debug per abilitarli.');
}

admin.initializeApp({
    credential: admin.credential.cert(serviceAccount)
});

const wss = new WebSocketServer({ port: 3000 });

// Utenti CONNESSI ora (WebSocket aperto): publicKeyHash -> { ws, nickname }
const clients = new Map();

// Posizioni PERSISTENTI di tutti gli utenti (sopravvive alla disconnessione):
// publicKeyHash -> { nickname, publicKey, lat, lon, age, gender, bio, fcmToken, lastSeen }
const knownUsers = new Map();

// Messaggi in coda per utenti offline: recipientHash -> Array di messaggi
const offlineMessages = new Map();

// Ricevute di consegna in coda per utenti offline: recipientHash -> Array di ricevute
const offlineReceipts = new Map();

// ── Persistenza del database su File System ───────────────────────────────────
const fs = require('fs');
const path = require('path');
const DB_PATH = path.join(__dirname, 'server_db.json');

let saveTimeout = null;
function triggerSave() {
    if (saveTimeout) return;
    saveTimeout = setTimeout(() => {
        saveTimeout = null;
        try {
            const data = {
                knownUsers: Array.from(knownUsers.entries()),
                offlineMessages: Array.from(offlineMessages.entries()),
                offlineReceipts: Array.from(offlineReceipts.entries())
            };
            fs.writeFile(DB_PATH, JSON.stringify(data, null, 2), 'utf8', (err) => {
                if (err) console.error('[DB] Errore scrittura database:', err);
            });
        } catch (err) {
            console.error('[DB] Errore serializzazione database:', err);
        }
    }, 1000); // Scrivi al massimo una volta al secondo (debouncing)
}

function loadDatabase() {
    try {
        if (fs.existsSync(DB_PATH)) {
            const raw = fs.readFileSync(DB_PATH, 'utf8');
            const data = JSON.parse(raw);
            if (data.knownUsers) {
                for (const [key, val] of data.knownUsers) {
                    knownUsers.set(key, val);
                }
            }
            if (data.offlineMessages) {
                for (const [key, val] of data.offlineMessages) {
                    offlineMessages.set(key, val);
                }
            }
            if (data.offlineReceipts) {
                for (const [key, val] of data.offlineReceipts) {
                    offlineReceipts.set(key, val);
                }
            }
            console.log(`[DB] Database caricato con successo: ${knownUsers.size} utenti, ${offlineMessages.size} code offline.`);
        } else {
            console.log('[DB] Nessun database trovato, avvio con database vuoto.');
        }
    } catch (err) {
        console.error('[DB] Errore caricamento database:', err);
    }
}

// Carica il database all'avvio
loadDatabase();

// Validità massima della posizione (1 ora)
const LOCATION_TIMEOUT = 60 * 60 * 1000; 

// Inattività massima per pulizia RAM (24 ore)
const RAM_CLEANUP_TIMEOUT = 24 * 60 * 60 * 1000;

// Raggio di prossimità configurabile (default 500m)
let maxDistance = 500;

const distanceArgIndex = process.argv.indexOf('--distance');
if (distanceArgIndex !== -1 && distanceArgIndex + 1 < process.argv.length) {
    const rawVal = process.argv[distanceArgIndex + 1].toLowerCase().trim();
    const match = rawVal.match(/^(\d+(?:\.\d+)?)\s*(m|km)$/);
    if (match) {
        const value = parseFloat(match[1]);
        const unit = match[2];
        if (unit === 'km') {
            maxDistance = value * 1000;
        } else {
            maxDistance = value;
        }
        console.log(`[INIT] Raggio prossimità impostato a: ${maxDistance} metri (${rawVal})`);
    } else {
        console.error(`[ERROR] Formato distanza non valido: "${rawVal}". Usa ad esempio "200m" o "10km".`);
        process.exit(1);
    }
} else {
    console.log(`[INIT] Raggio prossimità di default impostato a: ${maxDistance} metri`);
}

// Pulisci periodicamente gli utenti inattivi per evitare perdite di memoria
setInterval(() => {
    const now = Date.now();
    for (const [hash, user] of knownUsers.entries()) {
        if (now - (user.lastSeen || 0) > RAM_CLEANUP_TIMEOUT) {
            knownUsers.delete(hash);
            console.log(`[CLEANUP] Rimosso utente inattivo dalla memoria: ${user.nickname}`);
            triggerSave();
        }
    }
}, 60 * 60 * 1000); // Esegui la pulizia ogni ora

// ─── Calcolo distanza Haversine ────────────────────────────────────────────────
function calculateDistance(lat1, lon1, lat2, lon2) {
    if (lat1 == null || lon1 == null || lat2 == null || lon2 == null) return Infinity;
    const R = 6371e3;
    const phi1 = lat1 * Math.PI / 180;
    const phi2 = lat2 * Math.PI / 180;
    const deltaPhi = (lat2 - lat1) * Math.PI / 180;
    const deltaLambda = (lon2 - lon1) * Math.PI / 180;
    const a = Math.sin(deltaPhi / 2) ** 2 +
              Math.cos(phi1) * Math.cos(phi2) * Math.sin(deltaLambda / 2) ** 2;
    return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// ─── Broadcast radar agli utenti CONNESSI ─────────────────────────────────────
// Confronta la posizione di ogni client connesso con TUTTE le posizioni note
// (anche di chi è offline). Invia aggiornamento solo a chi ha l'app aperta.
function broadcastNearbyUsers() {
    const activeHashes = Array.from(clients.keys());
    // Conteggio connessi: ok in produzione (nessun dato sensibile)
    console.log(`[BROADCAST] Connessi: ${activeHashes.length} | Posizioni note: ${knownUsers.size}`);

    for (const [hash, client] of clients.entries()) {
        const me = knownUsers.get(hash);
        if (!me || me.lat == null) {
            debugLog(`[BROADCAST] ${client.nickname}: posizione GPS non ancora disponibile, skip.`);
            continue;
        }

        const nearby = [];
        for (const [otherHash, other] of knownUsers.entries()) {
            if (otherHash === hash) continue;

            // Salta gli utenti invisibili
            if (other.status === 'invisible') continue;

            // Salta posizioni non aggiornate da più del timeout (1 ora)
            const locationAge = Date.now() - (other.lastSeen || 0);
            if (locationAge > LOCATION_TIMEOUT) continue;

            const myRange = me.radarRange || 500;
            const otherRange = other.radarRange || 500;
            const maxAllowedDistance = Math.min(myRange, otherRange);

            const dist = calculateDistance(me.lat, me.lon, other.lat, other.lon);
            const isOnline = clients.has(otherHash);
            if (dist <= maxAllowedDistance) {
                const isSharing = other.sharingWith && other.sharingWith.includes(hash);
                // Distanze e coordinate: solo in modalità debug
                debugLog(`[BROADCAST] ${client.nickname} <-> ${other.nickname}: ${Math.round(dist)}m ✓ (${isOnline ? 'online' : 'offline'}), condivisionePrecisa: ${isSharing}`);
                nearby.push({
                    publicKeyHash: otherHash,
                    nickname: other.nickname,
                    publicKey: other.publicKey,
                    x25519PublicKey: other.x25519PublicKey,
                    distance: isSharing ? dist : null,
                    age: other.age,
                    gender: other.gender,
                    bio: other.bio,
                    isOnline,
                });
            }
        }

        debugLog(`[BROADCAST] -> ${client.nickname} vede ${nearby.length} utenti vicini`);
        client.ws.send(JSON.stringify({
            type: 'nearby_users',
            data: {
                nearby,
                activeUsers: activeHashes
            }
        }));
    }
}

// ─── Invio push UnifiedPush ───────────────────────────────────────────────────
function sendUnifiedPush(endpoint, senderHash, senderNickname, msgType) {
    debugLog(`[UnifiedPush] Invio push a ${endpoint.substring(0, 30)}...`);
    const bodyText = msgType === 'photoRequest' ? 'Richiesta foto profilo' : 'Hai ricevuto un nuovo messaggio';
    
    const payload = JSON.stringify({
        type: 'message',
        senderHash: senderHash,
        senderNickname: senderNickname,
        content: bodyText
    });
    
    try {
        const parsedUrl = new URL(endpoint);
        const options = {
            hostname: parsedUrl.hostname,
            path: parsedUrl.pathname + parsedUrl.search,
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(payload)
            }
        };
        
        const req = https.request(options, (res) => {
            let responseData = '';
            res.on('data', (chunk) => { responseData += chunk; });
            res.on('end', () => {
                console.log(`[UnifiedPush] Notifica inviata con successo. Stato: ${res.statusCode}`);
            });
        });
        
        req.on('error', (err) => {
            console.error('[UnifiedPush] ERRORE invio notifica:', err.message);
        });
        
        req.write(payload);
        req.end();
    } catch (e) {
        console.error('[UnifiedPush] ERRORE parsing URL endpoint:', e.message);
    }
}

// ─── Dispacher notifiche push ───────────────────────────────────────────────
function sendPushNotification(recipientHash, senderHash, senderNickname, msgType) {
    const user = knownUsers.get(recipientHash);
    if (!user || !user.pushToken) {
        debugLog(`[PUSH] Nessun token/endpoint per ${recipientHash} - push impossibile`);
        return;
    }
    
    const provider = user.pushProvider || 'fcm';
    
    if (provider === 'unifiedpush') {
        sendUnifiedPush(user.pushToken, senderHash, senderNickname, msgType);
    } else {
        // FCM Fallback — token sensibile: solo in debug
        debugLog(`[FCM] Invio push a ${user.nickname} (token: ${user.pushToken.substring(0, 20)}...)`);
        const body = msgType === 'photoRequest' ? 'Richiesta foto profilo' : 'Hai ricevuto un nuovo messaggio';
        admin.messaging().send({
            token: user.pushToken,
            notification: {
                title: `Nuovo messaggio da ${senderNickname}`,
                body,
            },
            data: {
                type: 'message_notification',
                senderHash: senderHash,
                senderNickname: senderNickname
            }
        })
        .then(id  => console.log(`[FCM] Push inviata! Message ID: ${id}`))
        .catch(err => console.error(`[FCM] ERRORE push: ${err.code} - ${err.message}`));
    }
}

// ─── Gestione connessioni WebSocket ───────────────────────────────────────────
wss.on('connection', (ws) => {
    let clientHash = null;

    ws.on('message', (message) => {
        try {
            const { type, data } = JSON.parse(message);

            // ── Registrazione utente ────────────────────────────────────────
            if (type === 'register') {
                const { publicKeyHash, nickname, publicKey, x25519PublicKey, lat, lon, age, gender, bio, fcmToken, pushProvider, pushToken, status, radarRange, sharingWith } = data;
                
                // Sanity check dell'identificativo hash
                if (!publicKeyHash || typeof publicKeyHash !== 'string') {
                    console.error('[ERROR] Registrazione fallita: publicKeyHash non valido.');
                    return;
                }
                clientHash = publicKeyHash;

                // Sanity check lato server: tronca e pulisce nickname, bio, gender
                const safeNickname = (typeof nickname === 'string')
                    ? nickname.replace(/[\x00-\x1F\x7F<>]/g, '').substring(0, 20).trim() || 'Utente'
                    : 'Utente';
                const safeBio = (typeof bio === 'string')
                    ? bio.replace(/[\x00-\x1F\x7F<>]/g, '').substring(0, 150)
                    : null;
                const safeGender = (typeof gender === 'string')
                    ? gender.replace(/[\x00-\x1F\x7F<>]/g, '').substring(0, 20)
                    : null;

                // Validazione Coordinate GPS
                let safeLat = null;
                let safeLon = null;
                if (typeof lat === 'number' && !isNaN(lat) && lat >= -90 && lat <= 90) {
                    safeLat = lat;
                }
                if (typeof lon === 'number' && !isNaN(lon) && lon >= -180 && lon <= 180) {
                    safeLon = lon;
                }

                // Validazione Raggio Radar
                let safeRadarRange = 500;
                if (typeof radarRange === 'number' && !isNaN(radarRange)) {
                    safeRadarRange = Math.max(500, Math.min(1000000, radarRange));
                }

                // Validazione Stato Profilo
                const allowedStatus = ['available', 'unavailable', 'invisible'];
                const safeStatus = allowedStatus.includes(status) ? status : 'available';

                // Validazione Sharing List
                const safeSharingWith = Array.isArray(sharingWith)
                    ? sharingWith.filter(h => typeof h === 'string' && h.length < 100).slice(0, 100)
                    : [];

                // Aggiorna connessione attiva
                clients.set(clientHash, { ws, nickname: safeNickname });

                // Aggiorna/crea il profilo persistente dell'utente
                const existing = knownUsers.get(clientHash) || {};
                const currentPushProvider = pushProvider ?? existing.pushProvider ?? 'fcm';
                const currentPushToken = pushToken ?? fcmToken ?? existing.pushToken;

                knownUsers.set(clientHash, {
                    ...existing,
                    nickname: safeNickname,
                    publicKey,
                    x25519PublicKey,
                    age: (typeof age === 'number' && !isNaN(age)) ? Math.max(0, Math.min(120, age)) : existing.age,
                    gender: safeGender,
                    bio: safeBio,
                    lat: safeLat ?? existing.lat,
                    lon: safeLon ?? existing.lon,
                    pushProvider: currentPushProvider,
                    pushToken: currentPushToken,
                    status: safeStatus,
                    radarRange: safeRadarRange,
                    sharingWith: safeSharingWith,
                    lastSeen: Date.now(),
                });
                triggerSave();

                // Token push e coordinate GPS: solo in modalità debug
                if (currentPushToken) {
                    debugLog(`[PUSH] Provider: ${currentPushProvider}, Token: ${currentPushToken.substring(0, 20)}...`);
                } else {
                    debugLog(`[PUSH] Nessun token registrato per ${safeNickname}`);
                }
                debugLog(`[INFO] Registrato: ${safeNickname} (${publicKeyHash}) Lat: ${safeLat}, Lon: ${safeLon}, Range: ${safeRadarRange}m, Sharing: ${JSON.stringify(safeSharingWith)}`);
                // Log produzione: solo nickname e hash (nessun dato sensibile)
                console.log(`[INFO] Registrato: ${safeNickname} (hash: ...${publicKeyHash.slice(-8)})`);

                // Consegna messaggi offline accumulati
                if (offlineMessages.has(clientHash)) {
                    const pending = offlineMessages.get(clientHash);
                    console.log(`[INFO] Consegno ${pending.length} messaggi in coda a ${safeNickname}`);
                    for (const msg of pending) {
                        ws.send(JSON.stringify({ type: 'message', data: msg }));
                    }
                    // Rimangono in coda offline finché non arriva il relativo delivery_receipt (ACK) dal client
                }

                // Consegna ricevute di consegna offline accumulate
                if (offlineReceipts.has(clientHash)) {
                    const pendingRecs = offlineReceipts.get(clientHash);
                    console.log(`[INFO] Consegno ${pendingRecs.length} ricevute di consegna in coda a ${safeNickname}`);
                    for (const rec of pendingRecs) {
                        ws.send(JSON.stringify(rec));
                    }
                    offlineReceipts.delete(clientHash);
                    triggerSave();
                }

                broadcastNearbyUsers();

            // ── Aggiornamento GPS ────────────────────────────────────────────
            } else if (type === 'location_update') {
                const { lat, lon, status, radarRange, sharingWith } = data;
                if (clientHash && knownUsers.has(clientHash)) {
                    const user = knownUsers.get(clientHash);
                    
                    // Validazione Coordinate GPS
                    if (typeof lat === 'number' && !isNaN(lat) && lat >= -90 && lat <= 90) {
                        user.lat = lat;
                    }
                    if (typeof lon === 'number' && !isNaN(lon) && lon >= -180 && lon <= 180) {
                        user.lon = lon;
                    }
                    
                    // Validazione Stato Profilo
                    const allowedStatus = ['available', 'unavailable', 'invisible'];
                    if (status !== undefined && allowedStatus.includes(status)) {
                        user.status = status;
                    }
                    
                    // Validazione Raggio Radar
                    if (radarRange !== undefined && typeof radarRange === 'number' && !isNaN(radarRange)) {
                        user.radarRange = Math.max(500, Math.min(1000000, radarRange));
                    }
                    
                    // Validazione Sharing List
                    if (sharingWith !== undefined && Array.isArray(sharingWith)) {
                        user.sharingWith = sharingWith.filter(h => typeof h === 'string' && h.length < 100).slice(0, 100);
                    }
                    
                    user.lastSeen = Date.now();
                    // Coordinate GPS: solo in modalità debug
                    debugLog(`[INFO] GPS update per ${user.nickname}: ${user.lat}, ${user.lon}, Status: ${user.status}, Range: ${user.radarRange}m, Sharing: ${JSON.stringify(user.sharingWith)}`);
                    console.log(`[INFO] GPS update: ${user.nickname} (status: ${user.status})`);
                    triggerSave();
                    broadcastNearbyUsers();
                }

            // ── Messaggio tra utenti ─────────────────────────────────────────
            } else if (type === 'message') {
                const { recipientHash, senderHash, encryptedMessage, type: msgType, photoData, messageId } = data;

                // Se non è fornito il messageId (es. per richieste di sistema come posizione o foto), ne generiamo uno
                const safeMessageId = (messageId && typeof messageId === 'string')
                    ? messageId
                    : `sys_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;

                // Sanity checks sugli identificativi
                if (!recipientHash || typeof recipientHash !== 'string' ||
                    !senderHash || typeof senderHash !== 'string') {
                    console.warn(`[WARN] Messaggio rifiutato: parametri ID non validi.`);
                    return;
                }

                const allowedMsgTypes = [
                    'text', 'image', 'file', 
                    'photoRequest', 'photoResponse', 'photoRejected', 
                    'locationRequest', 'locationResponse', 'locationRejected'
                ];
                if (!msgType || !allowedMsgTypes.includes(msgType)) {
                    console.warn(`[WARN] Messaggio rifiutato: tipo messaggio "${msgType}" non riconosciuto.`);
                    return;
                }

                // Sanity check sulla lunghezza del testo cifrato (massimo 1500 caratteri base64, circa 500 caratteri di testo in chiaro)
                if (encryptedMessage && typeof encryptedMessage === 'string' && encryptedMessage.length > 1500) {
                    console.warn(`[WARN] Messaggio rifiutato: il contenuto cifrato supera il limite consentito (${encryptedMessage.length} caratteri).`);
                    return;
                }

                // Sanity check sul peso delle immagini/avatar di profilo (massimo 300KB in base64)
                if (photoData && typeof photoData === 'string' && photoData.length > 400000) {
                    console.warn(`[WARN] Messaggio rifiutato: dati foto profilo troppo pesanti (${photoData.length} caratteri).`);
                    return;
                }

                const sender = knownUsers.get(senderHash);
                const senderNickname = sender?.nickname ?? 'Utente';

                const messagePayload = {
                    messageId: safeMessageId,
                    senderHash,
                    senderNickname,
                    senderPublicKey: typeof data.senderPublicKey === 'string' ? data.senderPublicKey.substring(0, 1000) : undefined,
                    senderX25519PublicKey: typeof data.senderX25519PublicKey === 'string' ? data.senderX25519PublicKey.substring(0, 200) : undefined,
                    encryptedMessage: typeof encryptedMessage === 'string' ? encryptedMessage : undefined,
                    type: msgType,
                    photoData: typeof photoData === 'string' ? photoData : undefined,
                    timestamp: Date.now()
                };

                // Invia immediatamente la ricevuta di presa in carico al server (spunta grigia)
                ws.send(JSON.stringify({
                    type: 'server_ack',
                    data: {
                        messageId: safeMessageId,
                        recipientHash
                    }
                }));

                // Accoda SEMPRE nella coda offline per sicurezza (verrà rimosso solo con delivery_receipt)
                if (!offlineMessages.has(recipientHash)) {
                    offlineMessages.set(recipientHash, []);
                }
                const queue = offlineMessages.get(recipientHash);
                if (!queue.some(m => m.messageId === safeMessageId)) {
                    queue.push(messagePayload);
                    triggerSave();
                }

                const recipientConn = clients.get(recipientHash);
                if (recipientConn) {
                    // Destinatario online: prova a consegnare immediatamente via WebSocket
                    recipientConn.ws.send(JSON.stringify({ type: 'message', data: messagePayload }));
                    console.log(`[INFO] Messaggio WS inviato: ${senderNickname} -> ${recipientHash} (in attesa di ACK)`);

                    // Se non riceviamo l'ACK entro 3 secondi (es. socket morto silente o app sospesa in background),
                    // inviamo la notifica push per risvegliare il destinatario o notificarlo offline
                    setTimeout(() => {
                        if (offlineMessages.has(recipientHash)) {
                            const queue = offlineMessages.get(recipientHash);
                            const stillPending = queue.some(m => m.messageId === safeMessageId);
                            if (stillPending) {
                                console.log(`[PUSH] Nessun ACK ricevuto entro 3s per msg ${safeMessageId}. Invio push a ${recipientHash}.`);
                                sendPushNotification(recipientHash, senderHash, senderNickname, msgType);
                            }
                        }
                    }, 3000);
                } else {
                    // Destinatario offline: invia push FCM immediatamente
                    console.log(`[INFO] ${recipientHash} offline. Invio push FCM.`);
                    sendPushNotification(recipientHash, senderHash, senderNickname, msgType);
                }

            // ── Ricevuta di consegna (spunta blu) ─────────────────────────────
            } else if (type === 'delivery_receipt') {
                const { messageId, senderHash } = data; // senderHash è il mittente originale (Alice)
                const ackPayload = {
                    messageId,
                    recipientHash: clientHash // Chi ha confermato la ricezione (Bob)
                };

                // Rimuovi il messaggio confermato dalla coda offline del destinatario (Bob)
                if (clientHash && offlineMessages.has(clientHash)) {
                    const queue = offlineMessages.get(clientHash);
                    const index = queue.findIndex(m => m.messageId === messageId);
                    if (index !== -1) {
                        queue.splice(index, 1);
                        console.log(`[QUEUE] Messaggio ${messageId} confermato e rimosso dalla coda offline di ${clientHash}`);
                        triggerSave();
                    }
                }

                const senderConn = clients.get(senderHash);
                if (senderConn) {
                    // Alice è online: recapito immediato
                    senderConn.ws.send(JSON.stringify({ type: 'msg_delivered', data: ackPayload }));
                    console.log(`[INFO] Ricevuta di consegna WS: ${clientHash} -> ${senderHash} per msg ${messageId}`);
                } else {
                    // Alice è offline: accoda
                    console.log(`[INFO] Mittente ${senderHash} offline. Accodo ricevuta per msg ${messageId}.`);
                    if (!offlineReceipts.has(senderHash)) offlineReceipts.set(senderHash, []);
                    offlineReceipts.get(senderHash).push({ type: 'msg_delivered', data: ackPayload });
                    triggerSave();
                }
            }
        } catch (e) {
            console.error('[ERROR] Errore processing messaggio:', e);
        }
    });

    ws.on('close', () => {
        if (clientHash) {
            clients.delete(clientHash);
            // NON eliminiamo da knownUsers: la posizione resta nota anche da offline
            const user = knownUsers.get(clientHash);
            console.log(`[INFO] Disconnesso: ${user?.nickname ?? clientHash}`);
            broadcastNearbyUsers(); // Aggiorna chi è ancora online
        }
    });
});

console.log('CatchMe Hybrid Proximity Server running on port 3000');
