import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { appendFile, mkdir } from 'fs/promises';
import { dirname } from 'path';

const LEVELS = ['INFO', 'INFO', 'INFO', 'WARN', 'ERROR', 'DEBUG'];
const MESSAGES = [
  'requisição processada com sucesso',
  'cache miss, buscando do banco',
  'timeout ao chamar serviço externo',
  'usuário autenticado',
  'fila de processamento com atraso',
  'job agendado executado',
  'conexão com banco reestabelecida',
  'payload inválido recebido',
];

@Injectable()
export class LogGeneratorService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(LogGeneratorService.name);
  private timer?: NodeJS.Timeout;
  private readonly appName = process.env.APP_NAME ?? 'app';
  private readonly logFile = process.env.LOG_FILE ?? `/var/log/app/${this.appName}.log`;

  async onModuleInit() {
    await mkdir(dirname(this.logFile), { recursive: true });
    this.logger.log(`Escrevendo logs de "${this.appName}" em ${this.logFile}`);
    this.scheduleNext();
  }

  onModuleDestroy() {
    if (this.timer) clearTimeout(this.timer);
  }

  private scheduleNext() {
    const delay = 1000 + Math.floor(Math.random() * 2000);
    this.timer = setTimeout(() => {
      this.writeLogLine().finally(() => this.scheduleNext());
    }, delay);
  }

  private async writeLogLine() {
    const level = LEVELS[Math.floor(Math.random() * LEVELS.length)];
    const message = MESSAGES[Math.floor(Math.random() * MESSAGES.length)];
    const line = `${new Date().toISOString()} [${level}] ${this.appName}: ${message}\n`;
    await appendFile(this.logFile, line);
  }
}
