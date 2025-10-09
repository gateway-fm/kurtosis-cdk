\connect master master_user;
CREATE USER bridge_user with password 'secret';
CREATE DATABASE bridge_db OWNER bridge_user;
grant all privileges on database bridge_db to bridge_user;
