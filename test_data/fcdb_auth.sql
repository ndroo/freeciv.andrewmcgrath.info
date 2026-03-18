PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE fcdb_auth (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name VARCHAR(48) default NULL UNIQUE,
  password VARCHAR(32) default NULL,
  email VARCHAR default NULL,
  createtime INTEGER default NULL,
  accesstime INTEGER default NULL,
  address VARCHAR default NULL,
  createaddress VARCHAR default NULL,
  logincount INTEGER default '0'
);
INSERT INTO fcdb_auth VALUES(5,'shazow','xxx','test-shazow@example.com',1773155975,1773155975,'','',0);
INSERT INTO fcdb_auth VALUES(6,'hyfen','xxx','test-hyfen@example.com',1773155981,1773155981,'','',0);
INSERT INTO fcdb_auth VALUES(7,'blakkout','xxx','test-blakkout@example.com',1773155987,1773155987,'','',0);
INSERT INTO fcdb_auth VALUES(8,'jess','xxx','test-jess@example.com',1773155992,1773155992,'','',0);
INSERT INTO fcdb_auth VALUES(9,'andrew','xxx','test-andrew@example.com',1773155998,1773155998,'','',0);
INSERT INTO fcdb_auth VALUES(10,'jamsem24','xxx','test-jamsem24@example.com',1773156004,1773156004,'','',0);
INSERT INTO fcdb_auth VALUES(11,'minikeg','xxx','test-minikeg@example.com',1773156010,1773156010,'','',0);
INSERT INTO fcdb_auth VALUES(12,'tracymakes','xxx','test-tracymakes@example.com',1773156016,1773156016,'','',0);
INSERT INTO fcdb_auth VALUES(13,'ihop','xxx','test-ihop@example.com',1773156021,1773156021,'','',0);
INSERT INTO fcdb_auth VALUES(14,'shogun','xxx','test-shogun@example.com',1773156027,1773156027,'','',0);
INSERT INTO fcdb_auth VALUES(15,'kimjongboom','xxx','test-kimjongboom@example.com',1773156033,1773156033,'','',0);
INSERT INTO fcdb_auth VALUES(16,'kroony','xxx','test-kroony@example.com',1773156039,1773156039,'','',0);
INSERT INTO fcdb_auth VALUES(17,'tankerjon','xxx','test-tankerjon@example.com',1773156045,1773156045,'','',0);
INSERT INTO fcdb_auth VALUES(18,'peter','xxx','test-peter@example.com',1773156050,1773156050,'','',0);
INSERT INTO fcdb_auth VALUES(20,'DetectiveG','xxx','test-detectiveg@example.com',1773184205,1773184205,'','',0);
COMMIT;
