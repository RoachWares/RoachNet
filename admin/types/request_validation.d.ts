declare module '@adonisjs/core/http' {
  interface Request {
    validateUsing<Validator extends { validate(data: unknown, ...args: unknown[]): unknown }>(
      validator: Validator,
      ...args: unknown[]
    ): Promise<Awaited<ReturnType<Validator['validate']>>>
  }
}

export {}
