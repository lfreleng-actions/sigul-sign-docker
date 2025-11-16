=== Database Schema ===
CREATE TABLE keys (
	id INTEGER NOT NULL,
	name TEXT NOT NULL,
	fingerprint TEXT NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (name),
	UNIQUE (fingerprint)
);
CREATE TABLE users (
	id INTEGER NOT NULL,
	name TEXT NOT NULL,
	sha512_password BLOB,
	admin BOOLEAN NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (name),
	CHECK (admin IN (0, 1))
);
CREATE TABLE key_accesses (
	id INTEGER NOT NULL,
	key_id INTEGER NOT NULL,
	user_id INTEGER NOT NULL,
	encrypted_passphrase BLOB NOT NULL,
	key_admin BOOLEAN NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (key_id, user_id),
	FOREIGN KEY(key_id) REFERENCES keys (id),
	FOREIGN KEY(user_id) REFERENCES users (id),
	CHECK (key_admin IN (0, 1))
);
