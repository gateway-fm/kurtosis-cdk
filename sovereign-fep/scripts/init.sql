\connect master master_user;
CREATE USER aggregator_user with password 'secret';
CREATE DATABASE aggregator_db OWNER aggregator_user;
grant all privileges on database aggregator_db to aggregator_user;

\connect master master_user;
CREATE USER aggregator_syncer_db_user with password 'secret';
CREATE DATABASE aggregator_syncer_db OWNER aggregator_syncer_db_user;
grant all privileges on database aggregator_syncer_db to aggregator_syncer_db_user;

\connect master master_user;
CREATE USER bridge_user with password 'secret';
CREATE DATABASE bridge_db OWNER bridge_user;
grant all privileges on database bridge_db to bridge_user;

\connect master master_user;
CREATE USER dac_user with password 'secret';
CREATE DATABASE dac_db OWNER dac_user;
grant all privileges on database dac_db to dac_user;

\connect master master_user;
CREATE USER prover_user with password 'secret';
CREATE DATABASE prover_db OWNER prover_user;
\connect prover_db prover_user;
CREATE SCHEMA state;
CREATE TABLE state.nodes (hash BYTEA PRIMARY KEY, data BYTEA NOT NULL);
CREATE TABLE state.program (hash BYTEA PRIMARY KEY, data BYTEA NOT NULL);
grant all privileges on database prover_db to prover_user;

\connect master master_user;
CREATE USER pool_manager_user with password 'secret';
CREATE DATABASE pool_manager_db OWNER pool_manager_user;
grant all privileges on database pool_manager_db to pool_manager_user;

\connect master master_user;
CREATE USER op_succinct_user with password 'secret';
CREATE DATABASE op_succinct_db OWNER op_succinct_user;
grant all privileges on database op_succinct_db to op_succinct_user;
