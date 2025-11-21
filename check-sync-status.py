#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Script de Verificação de Sincronização MySQL <-> SQLite
Compara os dados entre os dois bancos e exibe diferenças
"""

import sqlite3
import pymysql
import sys
import json
from datetime import datetime
from typing import Dict, List
from tabulate import tabulate

class SyncChecker:
    """Verifica sincronização entre MySQL e SQLite"""
    
    def __init__(self, config_file: str):
        with open(config_file, 'r') as f:
            config = json.load(f)
        
        self.mysql_config = config['mysql']
        self.sqlite_path = config['sqlite']['path']
        self.tables = ['tb_mail_domain', 'tb_mail_mailbox', 'tb_mail_alias']
        self.primary_keys = {
            'tb_mail_domain': 'cd_domain',
            'tb_mail_mailbox': 'cd_mailbox',
            'tb_mail_alias': 'cd_alias'
        }
    
    def connect_mysql(self):
        """Conecta ao MySQL"""
        return pymysql.connect(
            host=self.mysql_config['host'],
            port=self.mysql_config['port'],
            user=self.mysql_config['user'],
            password=self.mysql_config['password'],
            database=self.mysql_config['database'],
            charset='utf8mb4',
            cursorclass=pymysql.cursors.DictCursor
        )
    
    def connect_sqlite(self):
        """Conecta ao SQLite"""
        conn = sqlite3.connect(self.sqlite_path)
        conn.row_factory = sqlite3.Row
        return conn
    
    def get_count(self, conn, table: str, is_mysql: bool = False) -> int:
        """Conta registros em uma tabela"""
        if is_mysql:
            cursor = conn.cursor()
        else:
            cursor = conn.cursor()
        
        cursor.execute(f"SELECT COUNT(*) as count FROM {table}")
        
        if is_mysql:
            result = cursor.fetchone()
            count = result['count']
        else:
            result = cursor.fetchone()
            count = result[0]
        
        cursor.close()
        return count
    
    def check_all(self):
        """Verifica todas as tabelas"""
        print("=" * 80)
        print("  VERIFICAÇÃO DE SINCRONIZAÇÃO MySQL <-> SQLite")
        print("=" * 80)
        print()
        
        mysql_conn = self.connect_mysql()
        sqlite_conn = self.connect_sqlite()
        
        results = []
        total_mysql = 0
        total_sqlite = 0
        
        for table in self.tables:
            mysql_count = self.get_count(mysql_conn, table, is_mysql=True)
            sqlite_count = self.get_count(sqlite_conn, table, is_mysql=False)
            
            diff = mysql_count - sqlite_count
            status = "✓ OK" if diff == 0 else f"⚠ DIFF: {diff:+d}"
            
            results.append([
                table,
                mysql_count,
                sqlite_count,
                status
            ])
            
            total_mysql += mysql_count
            total_sqlite += sqlite_count
        
        # Adicionar totais
        results.append([
            "TOTAL",
            total_mysql,
            total_sqlite,
            "✓ OK" if total_mysql == total_sqlite else f"⚠ DIFF: {total_mysql - total_sqlite:+d}"
        ])
        
        print(tabulate(
            results,
            headers=["Tabela", "MySQL", "SQLite", "Status"],
            tablefmt="grid"
        ))
        print()
        
        # Verificar última sincronização
        try:
            with open('/var/log/mysql-sqlite-sync.log', 'r') as f:
                lines = f.readlines()
                for line in reversed(lines):
                    if "SINCRONIZAÇÃO CONCLUÍDA" in line:
                        print(f"Última sincronização: {line.split(' - ')[0]}")
                        break
        except FileNotFoundError:
            print("Log de sincronização não encontrado")
        
        mysql_conn.close()
        sqlite_conn.close()
        
        return total_mysql == total_sqlite

if __name__ == '__main__':
    config_file = '/etc/postfix/db/sync-config.json'
    
    if len(sys.argv) > 1:
        config_file = sys.argv[1]
    
    try:
        checker = SyncChecker(config_file)
        success = checker.check_all()
        sys.exit(0 if success else 1)
    except Exception as e:
        print(f"Erro: {e}", file=sys.stderr)
        sys.exit(1)
