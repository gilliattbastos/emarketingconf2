#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Script de Sincronização MySQL -> SQLite
Sincroniza tabelas de email do MySQL para SQLite
Autor: Sistema de Email Marketing
Data: 2025-11-19
"""

import sqlite3
import pymysql
import logging
import sys
import hashlib
import json
from datetime import datetime
from typing import Dict, List, Tuple, Any
import argparse

# Configuração de logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/mysql-sqlite-sync.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)


class DatabaseConfig:
    """Configurações de banco de dados"""
    
    # MySQL
    MYSQL_HOST = 'localhost'
    MYSQL_PORT = 3306
    MYSQL_USER = 'root'
    MYSQL_PASSWORD = ''
    MYSQL_DATABASE = 'mailserver'
    
    # SQLite
    SQLITE_PATH = '/etc/postfix/db/mailserver.db'
    
    # Tabelas a sincronizar
    TABLES = ['tb_mail_domain', 'tb_mail_mailbox', 'tb_mail_alias']


class MySQLToSQLiteSync:
    """Classe para sincronização de dados MySQL -> SQLite"""
    
    def __init__(self, config: DatabaseConfig):
        self.config = config
        self.mysql_conn = None
        self.sqlite_conn = None
        self.stats = {
            'inserted': 0,
            'updated': 0,
            'unchanged': 0,
            'errors': 0
        }
    
    def connect_mysql(self) -> pymysql.connections.Connection:
        """Conecta ao banco MySQL"""
        try:
            conn = pymysql.connect(
                host=self.config.MYSQL_HOST,
                port=self.config.MYSQL_PORT,
                user=self.config.MYSQL_USER,
                password=self.config.MYSQL_PASSWORD,
                database=self.config.MYSQL_DATABASE,
                charset='utf8mb4',
                cursorclass=pymysql.cursors.DictCursor
            )
            logger.info(f"Conectado ao MySQL: {self.config.MYSQL_HOST}:{self.config.MYSQL_PORT}")
            return conn
        except Exception as e:
            logger.error(f"Erro ao conectar no MySQL: {e}")
            raise
    
    def connect_sqlite(self) -> sqlite3.Connection:
        """Conecta ao banco SQLite"""
        try:
            conn = sqlite3.connect(self.config.SQLITE_PATH)
            conn.row_factory = sqlite3.Row
            logger.info(f"Conectado ao SQLite: {self.config.SQLITE_PATH}")
            return conn
        except Exception as e:
            logger.error(f"Erro ao conectar no SQLite: {e}")
            raise
    
    def get_mysql_data(self, table: str) -> List[Dict]:
        """Busca todos os registros de uma tabela no MySQL"""
        try:
            cursor = self.mysql_conn.cursor()
            cursor.execute(f"SELECT * FROM {table}")
            data = cursor.fetchall()
            cursor.close()
            logger.info(f"MySQL: {len(data)} registros encontrados em {table}")
            return data
        except Exception as e:
            logger.error(f"Erro ao buscar dados do MySQL ({table}): {e}")
            raise
    
    def get_sqlite_data(self, table: str, primary_key: str) -> Dict[Any, Dict]:
        """Busca todos os registros de uma tabela no SQLite"""
        try:
            cursor = self.sqlite_conn.cursor()
            cursor.execute(f"SELECT * FROM {table}")
            rows = cursor.fetchall()
            cursor.close()
            
            # Criar dicionário indexado pela chave primária
            data = {}
            for row in rows:
                row_dict = dict(row)
                data[row_dict[primary_key]] = row_dict
            
            logger.info(f"SQLite: {len(data)} registros encontrados em {table}")
            return data
        except Exception as e:
            logger.error(f"Erro ao buscar dados do SQLite ({table}): {e}")
            raise
    
    def calculate_row_hash(self, row: Dict) -> str:
        """Calcula hash de um registro para detectar alterações"""
        # Ordenar as chaves para ter hash consistente
        row_str = json.dumps(row, sort_keys=True, default=str)
        return hashlib.md5(row_str.encode()).hexdigest()
    
    def sync_table_domain(self):
        """Sincroniza tabela tb_mail_domain"""
        table = 'tb_mail_domain'
        primary_key = 'cd_domain'
        
        logger.info(f"=== Sincronizando {table} ===")
        
        try:
            # Buscar dados
            mysql_data = self.get_mysql_data(table)
            sqlite_data = self.get_sqlite_data(table, primary_key)
            
            cursor = self.sqlite_conn.cursor()
            
            for mysql_row in mysql_data:
                pk_value = mysql_row[primary_key]
                
                # Preparar dados para comparação (remover chave primária do hash)
                mysql_row_compare = {k: v for k, v in mysql_row.items() if k != primary_key}
                
                if pk_value not in sqlite_data:
                    # Registro novo - INSERT
                    try:
                        cursor.execute(
                            f"""INSERT INTO {table} 
                            (cd_domain, domain, transport, created, active, storage_id)
                            VALUES (?, ?, ?, ?, ?, ?)""",
                            (
                                mysql_row['cd_domain'],
                                mysql_row['domain'],
                                mysql_row['transport'],
                                mysql_row['created'],
                                mysql_row['active'],
                                mysql_row['storage_id']
                            )
                        )
                        self.stats['inserted'] += 1
                        logger.info(f"  [INSERT] {table}: cd_domain={pk_value}, domain={mysql_row['domain']}")
                    except Exception as e:
                        logger.error(f"  [ERRO INSERT] {table}: cd_domain={pk_value} - {e}")
                        self.stats['errors'] += 1
                else:
                    # Registro existe - verificar se houve alteração
                    sqlite_row = sqlite_data[pk_value]
                    sqlite_row_compare = {k: v for k, v in sqlite_row.items() if k != primary_key}
                    
                    # Comparar hashes
                    mysql_hash = self.calculate_row_hash(mysql_row_compare)
                    sqlite_hash = self.calculate_row_hash(sqlite_row_compare)
                    
                    if mysql_hash != sqlite_hash:
                        # Registro foi alterado - UPDATE
                        try:
                            cursor.execute(
                                f"""UPDATE {table} SET 
                                domain = ?, 
                                transport = ?, 
                                created = ?, 
                                active = ?, 
                                storage_id = ?
                                WHERE cd_domain = ?""",
                                (
                                    mysql_row['domain'],
                                    mysql_row['transport'],
                                    mysql_row['created'],
                                    mysql_row['active'],
                                    mysql_row['storage_id'],
                                    pk_value
                                )
                            )
                            self.stats['updated'] += 1
                            logger.info(f"  [UPDATE] {table}: cd_domain={pk_value}, domain={mysql_row['domain']}")
                        except Exception as e:
                            logger.error(f"  [ERRO UPDATE] {table}: cd_domain={pk_value} - {e}")
                            self.stats['errors'] += 1
                    else:
                        self.stats['unchanged'] += 1
            
            self.sqlite_conn.commit()
            cursor.close()
            
        except Exception as e:
            logger.error(f"Erro ao sincronizar {table}: {e}")
            self.sqlite_conn.rollback()
            raise
    
    def sync_table_mailbox(self):
        """Sincroniza tabela tb_mail_mailbox"""
        table = 'tb_mail_mailbox'
        primary_key = 'cd_mailbox'
        
        logger.info(f"=== Sincronizando {table} ===")
        
        try:
            # Buscar dados
            mysql_data = self.get_mysql_data(table)
            sqlite_data = self.get_sqlite_data(table, primary_key)
            
            cursor = self.sqlite_conn.cursor()
            
            for mysql_row in mysql_data:
                pk_value = mysql_row[primary_key]
                
                # Preparar dados para comparação
                mysql_row_compare = {k: v for k, v in mysql_row.items() if k != primary_key}
                
                if pk_value not in sqlite_data:
                    # Registro novo - INSERT
                    try:
                        cursor.execute(
                            f"""INSERT INTO {table} 
                            (cd_mailbox, username, password, domain, active, active_send, storage_id)
                            VALUES (?, ?, ?, ?, ?, ?, ?)""",
                            (
                                mysql_row['cd_mailbox'],
                                mysql_row['username'],
                                mysql_row['password'],
                                mysql_row['domain'],
                                mysql_row['active'],
                                mysql_row['active_send'],
                                mysql_row['storage_id']
                            )
                        )
                        self.stats['inserted'] += 1
                        logger.info(f"  [INSERT] {table}: cd_mailbox={pk_value}, username={mysql_row['username']}")
                    except Exception as e:
                        logger.error(f"  [ERRO INSERT] {table}: cd_mailbox={pk_value} - {e}")
                        self.stats['errors'] += 1
                else:
                    # Registro existe - verificar alteração
                    sqlite_row = sqlite_data[pk_value]
                    sqlite_row_compare = {k: v for k, v in sqlite_row.items() if k != primary_key}
                    
                    mysql_hash = self.calculate_row_hash(mysql_row_compare)
                    sqlite_hash = self.calculate_row_hash(sqlite_row_compare)
                    
                    if mysql_hash != sqlite_hash:
                        # Registro foi alterado - UPDATE
                        try:
                            cursor.execute(
                                f"""UPDATE {table} SET 
                                username = ?, 
                                password = ?, 
                                domain = ?, 
                                active = ?, 
                                active_send = ?, 
                                storage_id = ?
                                WHERE cd_mailbox = ?""",
                                (
                                    mysql_row['username'],
                                    mysql_row['password'],
                                    mysql_row['domain'],
                                    mysql_row['active'],
                                    mysql_row['active_send'],
                                    mysql_row['storage_id'],
                                    pk_value
                                )
                            )
                            self.stats['updated'] += 1
                            logger.info(f"  [UPDATE] {table}: cd_mailbox={pk_value}, username={mysql_row['username']}")
                        except Exception as e:
                            logger.error(f"  [ERRO UPDATE] {table}: cd_mailbox={pk_value} - {e}")
                            self.stats['errors'] += 1
                    else:
                        self.stats['unchanged'] += 1
            
            self.sqlite_conn.commit()
            cursor.close()
            
        except Exception as e:
            logger.error(f"Erro ao sincronizar {table}: {e}")
            self.sqlite_conn.rollback()
            raise
    
    def sync_table_alias(self):
        """Sincroniza tabela tb_mail_alias"""
        table = 'tb_mail_alias'
        primary_key = 'cd_alias'
        
        logger.info(f"=== Sincronizando {table} ===")
        
        try:
            # Buscar dados
            mysql_data = self.get_mysql_data(table)
            sqlite_data = self.get_sqlite_data(table, primary_key)
            
            # Criar índice adicional por address+domain para verificar UNIQUE constraint
            sqlite_by_address_domain = {}
            for pk, row in sqlite_data.items():
                key = (row['address'], row['domain'])
                sqlite_by_address_domain[key] = row
            
            cursor = self.sqlite_conn.cursor()
            
            for mysql_row in mysql_data:
                pk_value = mysql_row[primary_key]
                address_domain_key = (mysql_row['address'], mysql_row['domain'])
                
                # Preparar dados para comparação
                mysql_row_compare = {k: v for k, v in mysql_row.items() if k != primary_key}
                
                # Verificar se existe por chave primária OU por address+domain (UNIQUE constraint)
                existing_by_pk = pk_value in sqlite_data
                existing_by_unique = address_domain_key in sqlite_by_address_domain
                
                if not existing_by_pk and not existing_by_unique:
                    # Registro novo - INSERT
                    try:
                        cursor.execute(
                            f"""INSERT INTO {table} 
                            (cd_alias, address, goto, domain, active)
                            VALUES (?, ?, ?, ?, ?)""",
                            (
                                mysql_row['cd_alias'],
                                mysql_row['address'],
                                mysql_row['goto'],
                                mysql_row['domain'],
                                mysql_row['active']
                            )
                        )
                        self.stats['inserted'] += 1
                        logger.info(f"  [INSERT] {table}: cd_alias={pk_value}, address={mysql_row['address']}@{mysql_row['domain']}")
                    except Exception as e:
                        logger.error(f"  [ERRO INSERT] {table}: cd_alias={pk_value}, address={mysql_row['address']}@{mysql_row['domain']} - {e}")
                        self.stats['errors'] += 1
                
                elif existing_by_unique and not existing_by_pk:
                    # Existe registro com mesmo address+domain mas cd_alias diferente
                    # Atualizar o registro existente com o novo cd_alias
                    existing_row = sqlite_by_address_domain[address_domain_key]
                    old_pk = existing_row[primary_key]
                    
                    try:
                        # Atualizar usando address+domain como critério
                        cursor.execute(
                            f"""UPDATE {table} SET 
                            cd_alias = ?,
                            goto = ?, 
                            active = ?
                            WHERE address = ? AND domain = ?""",
                            (
                                mysql_row['cd_alias'],
                                mysql_row['goto'],
                                mysql_row['active'],
                                mysql_row['address'],
                                mysql_row['domain']
                            )
                        )
                        self.stats['updated'] += 1
                        logger.info(f"  [UPDATE PK] {table}: cd_alias {old_pk}->{pk_value}, address={mysql_row['address']}@{mysql_row['domain']}")
                    except Exception as e:
                        logger.error(f"  [ERRO UPDATE PK] {table}: cd_alias={pk_value} - {e}")
                        self.stats['errors'] += 1
                
                else:
                    # Registro existe - verificar alteração
                    sqlite_row = sqlite_data[pk_value]
                    sqlite_row_compare = {k: v for k, v in sqlite_row.items() if k != primary_key}
                    
                    mysql_hash = self.calculate_row_hash(mysql_row_compare)
                    sqlite_hash = self.calculate_row_hash(sqlite_row_compare)
                    
                    if mysql_hash != sqlite_hash:
                        # Registro foi alterado - UPDATE
                        try:
                            cursor.execute(
                                f"""UPDATE {table} SET 
                                address = ?, 
                                goto = ?, 
                                domain = ?, 
                                active = ?
                                WHERE cd_alias = ?""",
                                (
                                    mysql_row['address'],
                                    mysql_row['goto'],
                                    mysql_row['domain'],
                                    mysql_row['active'],
                                    pk_value
                                )
                            )
                            self.stats['updated'] += 1
                            logger.info(f"  [UPDATE] {table}: cd_alias={pk_value}, address={mysql_row['address']}@{mysql_row['domain']}")
                        except Exception as e:
                            logger.error(f"  [ERRO UPDATE] {table}: cd_alias={pk_value} - {e}")
                            self.stats['errors'] += 1
                    else:
                        self.stats['unchanged'] += 1
            
            self.sqlite_conn.commit()
            cursor.close()
            
        except Exception as e:
            logger.error(f"Erro ao sincronizar {table}: {e}")
            self.sqlite_conn.rollback()
            raise
    
    def sync_all(self):
        """Sincroniza todas as tabelas"""
        logger.info("========================================")
        logger.info("INICIANDO SINCRONIZAÇÃO MySQL -> SQLite")
        logger.info("========================================")
        
        start_time = datetime.now()
        
        try:
            # Conectar aos bancos
            self.mysql_conn = self.connect_mysql()
            self.sqlite_conn = self.connect_sqlite()
            
            # Sincronizar tabelas na ordem correta (domínios primeiro)
            self.sync_table_domain()
            self.sync_table_mailbox()
            self.sync_table_alias()
            
            # Fechar conexões
            self.mysql_conn.close()
            self.sqlite_conn.close()
            
            end_time = datetime.now()
            duration = (end_time - start_time).total_seconds()
            
            # Relatório final
            logger.info("========================================")
            logger.info("SINCRONIZAÇÃO CONCLUÍDA")
            logger.info("========================================")
            logger.info(f"Registros inseridos:  {self.stats['inserted']}")
            logger.info(f"Registros atualizados: {self.stats['updated']}")
            logger.info(f"Registros inalterados: {self.stats['unchanged']}")
            logger.info(f"Erros:                 {self.stats['errors']}")
            logger.info(f"Tempo de execução:     {duration:.2f} segundos")
            logger.info("========================================")
            
            return self.stats['errors'] == 0
            
        except Exception as e:
            logger.error(f"Erro durante a sincronização: {e}")
            if self.mysql_conn:
                self.mysql_conn.close()
            if self.sqlite_conn:
                self.sqlite_conn.close()
            return False


def load_config_from_file(config_file: str) -> DatabaseConfig:
    """Carrega configurações de um arquivo JSON"""
    try:
        with open(config_file, 'r') as f:
            config_data = json.load(f)
        
        config = DatabaseConfig()
        
        # MySQL
        if 'mysql' in config_data:
            config.MYSQL_HOST = config_data['mysql'].get('host', config.MYSQL_HOST)
            config.MYSQL_PORT = config_data['mysql'].get('port', config.MYSQL_PORT)
            config.MYSQL_USER = config_data['mysql'].get('user', config.MYSQL_USER)
            config.MYSQL_PASSWORD = config_data['mysql'].get('password', config.MYSQL_PASSWORD)
            config.MYSQL_DATABASE = config_data['mysql'].get('database', config.MYSQL_DATABASE)
        
        # SQLite
        if 'sqlite' in config_data:
            config.SQLITE_PATH = config_data['sqlite'].get('path', config.SQLITE_PATH)
        
        logger.info(f"Configurações carregadas de: {config_file}")
        return config
        
    except FileNotFoundError:
        logger.warning(f"Arquivo de configuração não encontrado: {config_file}")
        logger.info("Usando configurações padrão")
        return DatabaseConfig()
    except Exception as e:
        logger.error(f"Erro ao carregar configurações: {e}")
        logger.info("Usando configurações padrão")
        return DatabaseConfig()


def main():
    """Função principal"""
    parser = argparse.ArgumentParser(
        description='Sincronização MySQL -> SQLite para servidor de email'
    )
    parser.add_argument(
        '-c', '--config',
        default='/etc/postfix/db/sync-config.json',
        help='Arquivo de configuração JSON (padrão: /etc/postfix/db/sync-config.json)'
    )
    parser.add_argument(
        '--mysql-host',
        help='Host do MySQL'
    )
    parser.add_argument(
        '--mysql-user',
        help='Usuário do MySQL'
    )
    parser.add_argument(
        '--mysql-password',
        help='Senha do MySQL'
    )
    parser.add_argument(
        '--mysql-database',
        help='Database do MySQL'
    )
    parser.add_argument(
        '--sqlite-path',
        help='Caminho do banco SQLite'
    )
    
    args = parser.parse_args()
    
    # Carregar configurações
    config = load_config_from_file(args.config)
    
    # Sobrescrever com argumentos da linha de comando
    if args.mysql_host:
        config.MYSQL_HOST = args.mysql_host
    if args.mysql_user:
        config.MYSQL_USER = args.mysql_user
    if args.mysql_password:
        config.MYSQL_PASSWORD = args.mysql_password
    if args.mysql_database:
        config.MYSQL_DATABASE = args.mysql_database
    if args.sqlite_path:
        config.SQLITE_PATH = args.sqlite_path
    
    # Executar sincronização
    sync = MySQLToSQLiteSync(config)
    success = sync.sync_all()
    
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
