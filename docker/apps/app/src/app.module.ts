import { Module } from '@nestjs/common';
import { LogGeneratorService } from './log-generator.service';

@Module({
  providers: [LogGeneratorService],
})
export class AppModule {}
