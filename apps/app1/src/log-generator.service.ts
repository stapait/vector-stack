import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { appendFile, mkdir } from 'fs/promises';
import { dirname, resolve } from 'path';

// Nome desta app — o único trecho que muda entre apps/app1, apps/app2,
// apps/app3 (fora do package.json). Para uma 4ª app, copie esta pasta e
// troque só esta constante (e o filebeat.yml, ver apps/README.md).
const APP_NAME = 'app1';

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
  // dist/main.js roda de dentro de apps/appN/dist — resolve relativo a
  // __dirname (não ao cwd) para o log sempre cair em apps/appN/logs/,
  // não importa de onde `npm start` é chamado.
  private readonly logFile = resolve(__dirname, '..', 'logs', `${APP_NAME}.log`);

  async onModuleInit() {
    await mkdir(dirname(this.logFile), { recursive: true });
    this.logger.log(`Escrevendo logs de "${APP_NAME}" em ${this.logFile}`);
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
    const line = `${new Date().toISOString()} [${level}] ${APP_NAME}: ${message}\n`;
    await appendFile(this.logFile, line);
  }
}
