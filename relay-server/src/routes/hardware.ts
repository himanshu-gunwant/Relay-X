import { FastifyInstance } from 'fastify';
import { HardwareMonitorService } from '../services/hardware-monitor.js';

export async function hardwareRoutes(
  fastify: FastifyInstance,
  options: { hardwareMonitor: HardwareMonitorService }
) {
  fastify.get('/telemetry', async (request, reply) => {
    const data = options.hardwareMonitor.getTelemetry();
    return reply.send(data || { error: 'Telemetry not available yet' });
  });

  fastify.post('/fan-mode', async (request, reply) => {
    const { mode } = request.body as { mode: string };
    if (!mode) return reply.status(400).send({ error: 'mode is required' });
    
    const success = await options.hardwareMonitor.setFanMode(mode);
    return reply.send({ success });
  });

  fastify.post('/fan-level', async (request, reply) => {
    const { fan1, fan2 } = request.body as { fan1: number; fan2: number };
    if (fan1 === undefined || fan2 === undefined) return reply.status(400).send({ error: 'fan1 and fan2 are required' });
    
    const success = await options.hardwareMonitor.setFanLevel(fan1, fan2);
    return reply.send({ success });
  });

  fastify.post('/fan-max', async (request, reply) => {
    const { max } = request.body as { max: boolean };
    if (max === undefined) return reply.status(400).send({ error: 'max is required' });
    
    const success = await options.hardwareMonitor.setFanMax(max);
    return reply.send({ success });
  });
}
