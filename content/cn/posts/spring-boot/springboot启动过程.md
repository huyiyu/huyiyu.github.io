---
title: "Spring Boot 启动过程详解"
date: 2026-03-17
categories: ['Spring Boot']
draft: false
weight: 300
---

# Spring Boot 启动过程详解

本文结合源码，详细介绍 Spring Boot 的启动流程。

![Spring Boot 启动流程](/images/spring-boot/springboot-1.png)

## 1.1 SpringApplication 对象创建

创建 `SpringApplication` 对象本质上就是填充以下七个核心参数：

| 参数 | 说明 |
|------|------|
| `resourceLoader` | 资源加载器 |
| `primarySources` | 启动类列表，其中必须有一个带有 `@SpringBootApplication` 注解 |
| `webApplicationType` | 应用类型：Servlet 或 WebFlux |
| `bootstrappers` | 通过 SPI 机制加载的 Bootstrapper 列表 |
| `initializers` | 通过 SPI 机制加载的 ApplicationInitializer 列表 |
| `listeners` | 通过 SPI 机制加载的 ApplicationListener 列表 |
| `mainClass` | 包含 `main` 方法的启动类 |

### 1.1.1 缓存启动类参数

典型的 Spring Boot 启动代码如下：

```java
@SpringBootApplication
public class SpringbootSourceApplication {
    public static void main(String[] args) {
        // 第一个参数为配置类，第二个参数为命令行参数
        SpringApplication.run(SpringbootSourceApplication.class, args);
    }
}
```

`primarySources` 保存的是 `run()` 方法的第一个参数。熟悉 Spring 源码的读者应该知道，这个参数会被 `BeanDefinitionReader` 读取，用于创建 Bean 定义。

### 1.1.2 判断应用类型

Spring Boot 通过检查 classpath 中是否存在特定类来判断应用类型：

```java
NONE,
SERVLET,
REACTIVE;

private static final String[] SERVLET_INDICATOR_CLASSES = { 
    "javax.servlet.Servlet",
    "org.springframework.web.context.ConfigurableWebApplicationContext" 
};
private static final String WEBMVC_INDICATOR_CLASS = 
    "org.springframework.web.servlet.DispatcherServlet";
private static final String WEBFLUX_INDICATOR_CLASS = 
    "org.springframework.web.reactive.DispatcherHandler";

static WebApplicationType deduceFromClasspath() {
    if (ClassUtils.isPresent(WEBFLUX_INDICATOR_CLASS, null) 
            && !ClassUtils.isPresent(WEBMVC_INDICATOR_CLASS, null)) {
        return WebApplicationType.REACTIVE;
    }
    for (String className : SERVLET_INDICATOR_CLASSES) {
        if (!ClassUtils.isPresent(className, null)) {
            return WebApplicationType.NONE;
        }
    }
    return WebApplicationType.SERVLET;
}
```

**判断逻辑：**
- 如果存在 WebFlux 且不存在 WebMVC → **REACTIVE** 类型
- 如果不存在 Servlet 相关类 → **NONE** 类型
- 否则 → **SERVLET** 类型

### 1.1.3 Spring Boot SPI 加载机制

SPI（Service Provider Interface）是 Spring Boot 的核心扩展机制。启动时，Spring 会加载 classpath 下所有 `META-INF/spring.factories` 文件：

```java
private static Map<String, List<String>> loadSpringFactories(ClassLoader classLoader) {
    // 先从缓存中获取
    Map<String, List<String>> result = cache.get(classLoader);
    if (result != null) {
        return result;
    }

    result = new HashMap<>();
    try {
        // 加载所有 META-INF/spring.factories 文件
        Enumeration<URL> urls = classLoader.getResources(FACTORIES_RESOURCE_LOCATION);
        while (urls.hasMoreElements()) {
            URL url = urls.nextElement();
            Properties properties = PropertiesLoaderUtils.loadProperties(new UrlResource(url));
            
            // key 为接口名，value 为实现类列表（逗号分隔）
            for (Map.Entry<?, ?> entry : properties.entrySet()) {
                String factoryTypeName = ((String) entry.getKey()).trim();
                String[] factoryImplementationNames = StringUtils
                    .commaDelimitedListToStringArray((String) entry.getValue());
                
                for (String implementationName : factoryImplementationNames) {
                    result.computeIfAbsent(factoryTypeName, k -> new ArrayList<>())
                          .add(implementationName.trim());
                }
            }
        }

        // 去重并转为不可变列表
        result.replaceAll((type, implementations) -> implementations.stream()
            .distinct()
            .collect(Collectors.collectingAndThen(
                Collectors.toList(), 
                Collections::unmodifiableList
            )));
        cache.put(classLoader, result);
    } catch (IOException ex) {
        throw new IllegalArgumentException(
            "Unable to load factories from location [" + FACTORIES_RESOURCE_LOCATION + "]", ex);
    }
    return result;
}
```

通过 `getSpringFactoriesInstances()` 方法可以获取这些实现类的实例。

**核心 spring.factories 文件位置：**
- [spring-boot](https://github.com/huyiyu/spring-boot/blob/main/spring-boot-project/spring-boot-autoconfigure/src/main/resources/META-INF/spring.factories)
- [spring-boot-autoconfigure](https://github.com/huyiyu/spring-boot/blob/main/spring-boot-project/spring-boot/src/main/resources/META-INF/spring.factories)
- [spring-beans](https://github.com/huyiyu/spring-framework/blob/main/spring-beans/src/main/resources/META-INF/spring.factories)

**SPI 加载的核心组件：**
- **bootstrappers**：启动引导器
- **listeners**：事件监听器（Spring Boot 扩展了 Spring 的事件机制）
- **initializers**：在 `refresh()` 之前执行的扩展点

### 1.1.4 推断主启动类

Spring Boot 通过构造异常并分析堆栈信息来获取主类：

```java
private Class<?> deduceMainApplicationClass() {
    try {
        StackTraceElement[] stackTrace = new RuntimeException().getStackTrace();
        for (StackTraceElement element : stackTrace) {
            if ("main".equals(element.getMethodName())) {
                return Class.forName(element.getClassName());
            }
        }
    } catch (ClassNotFoundException ex) {
        // 忽略异常
    }
    return null;
}
```

## 1.2 SpringApplication.run() 方法

**相关概念补充：**
- **StopWatch**：用于统计执行时间的工具类。调用 `start()` 记录开始时间，`stop()` 记录结束时间，可获取各阶段耗时
- **java.awt.headless**：设置为 `true` 时，支持在无显示设备的环境（如服务器）中使用 AWT 相关 API（例如生成验证码）

### 1.2.1 注册 BootStrappers

Bootstrapper 是通过 [SPI 机制](#113-spring-boot-spi-加载机制)加载的。默认情况下，Spring Boot 本身不会加载任何 Bootstrapper，但 Spring Cloud 会加载 `TextEncryptorConfigBootstrapper`。

**DefaultBootstrapContext 的核心特性：**
- 采用两级缓存结构
- 一级缓存：`Map<Class, Supplier>`
- 二级缓存：`Map<Class, Object>`（缓存 Supplier 的执行结果）
- 通过 `register()` 方法注册 Supplier，在 Initializer 阶段初始化

### 1.2.2 发布 Starting 事件

涉及三个核心对象（详见[事件矩阵图](#事件矩阵图)）：

| 对象 | 说明 |
|------|------|
| `SpringApplicationRunListeners` | 监听器列表的封装对象 |
| `SpringApplicationRunListener` | Spring Boot 的事件发布订阅工具，默认实现为 `EventPublishingRunListener`，底层使用 `SimpleApplicationEventMulticaster` |
| `ApplicationListener` | 实际的事件监听器，与 Spring 原生事件机制兼容 |

### 1.2.3 创建 Environment 对象

Environment 的构建分为以下步骤：

1. **根据 [Web 应用类型](#112-判断应用类型)创建对应的 Environment**
   - 默认创建 `Servlet` 类型的 Environment
   - 初始包含 4 个 PropertySource：`servletConfigInitParams`、`servletContextInitParams`、`systemProperties`、`systemEnvironment`

2. **设置 ConversionService**（类型转换器）

3. **添加命令行参数 PropertySource**
   - 格式：`--key=value`
   - 设置为最高优先级，此时 PropertySource 变为 5 个

4. **包装 PropertySource 列表（可选深入了解）**
   > 核心结论：Spring 会对 PropertySource 列表进行包装，使其支持将 `.` 和 `-` 自动转换为 `_` 进行匹配。
   > 
   > 此时 PropertySource 变为 6 个，新增：`configurationProperties`、`random`
   > 
   > 详见[附录：Attach 解析](#attach-解析)

5. **发布 `environmentPrepared` 事件**

6. **将名为 `default` 的 PropertySource 移至最后**（默认为空）

7. **配置 Profile**（默认为空）

8. **将 `spring.main` 开头的配置绑定到 SpringApplication 对象**

9. **根据 Web 类型转换 Environment 类型**

10. **执行 Attach 操作**（如果已执行过会重新 Attach）

### 1.2.4 打印 Banner

1. **判断是否开启**：通过 `spring.main.banner-mode` 配置，可选值：`OFF`、`CONSOLE`、`LOG`
2. **支持多种形式**：
   - 图片：`banner.jpg`、`banner.gif`、`banner.jpeg`
   - 文本：`banner.txt`
   - 自定义路径：`spring.banner.location`、`spring.banner.image.location`
3. **优先使用 fallback Banner**（如果配置了）
4. **调用 `print()` 方法输出**（由具体子类实现）

### 创建 ApplicationContext

根据 [Web 应用类型](#112-判断应用类型)创建对应的上下文：
- 默认类型为 `AnnotationConfigServletWebServerApplicationContext`

### 准备 ApplicationContext

1. 设置 `Environment` 和 `ConversionService`
2. 执行 SPI 加载的 Initializer（详见[附录：Initializer 解析](#initializer-解析)）
3. 发布 `contextPrepared` 事件
4. 发布 BootstrapContext 关闭事件
5. 打印启动信息和激活的 Profiles
6. 向容器注册启动参数单例
7. 向容器注册 Banner 单例
8. 默认禁止 BeanDefinition 覆盖
9. 根据上下文类型创建对应的 `BeanDefinitionReader`，解析主类
10. 发布 `contextLoaded` 事件

### 执行 Refresh

详见 [Spring Boot Refresh 过程](./springboot%20Refresh%20过程.md)。

### 发布 Started 事件

### 调用 Runner

执行所有 `ApplicationRunner` 和 `CommandLineRunner` 的实现类。

---

## 附录

### 事件矩阵图

| 事件 \ 监听器 | EnvironmentPostProcessor | AnsiOutput | Logging | BackgroundPreinitializer | Delegating | ParentContextCloser | ClearCaches | FileEncoding | LiquibaseServiceLocator |
|:-------------:|:------------------------:|:----------:|:-------:|:------------------------:|:----------:|:-------------------:|:-----------:|:------------:|:-----------------------:|
| starting | - | - | 1 | 2 | 3 | - | - | - | 4 |
| environmentPrepared | 1 | 2 | 3 | 4 | 5 | - | - | 6 | - |
| contextPrepared | - | - | - | 1 | 2 | - | - | - | - |
| contextLoaded | 1 | - | 2 | 3 | 4 | - | - | - | - |
| started | - | - | 1 | 2 | - | - | - | - | - |
| running | | | | | | | | | |
| failed | | | | | | | | | |

#### starting

1. **LoggingApplicationListener**
   - 如果配置了 `org.springframework.boot.logging.LoggingSystem`，使用该日志系统
   - 否则从 [SPI 加载的列表](#113-spring-boot-spi-加载机制)中获取第一个作为默认日志系统
   - 执行预初始化

2. ~~BackgroundPreinitializer~~（此事件无业务逻辑）
3. ~~DelegatingApplicationListener~~（此事件无业务逻辑）
4. ~~LiquibaseServiceLocatorApplicationListener~~（未使用 Liquibase 时无逻辑）

#### environmentPrepared

1. **EnvironmentPostProcessorApplicationListener**
   - 创建并执行所有 [SPI 加载的 EnvironmentPostProcessor](#113-spring-boot-spi-加载机制)
   - 详见[附录：EnvironmentPostProcessor 解析](#environmentpostprocessor-解析)

2. **AnsiOutputApplicationListener**
   - 控制控制台彩色日志输出
   - 配置项 `spring.output.ansi.enabled`：
     - `ALWAYS`：强制开启
     - `DETECT`：自动检测（默认）
   - 注意：IDEA 的 Spring Boot 模板会在系统属性中修改默认值为 `ALWAYS`

3. **LoggingApplicationListener**
   - 初始化日志相关的环境变量
   - 注册 JVM 关闭钩子（ShutdownHook）

4. **BackgroundPreinitializer**
   - 后台预初始化：
     - `DefaultFormattingConversionService`
     - `Validator`
     - `AllEncompassingFormHttpMessageConverter`
     - `ObjectMapper`
     - `Charset`

5. **DelegatingApplicationListener**
   - 读取 `context.listener.classes` 配置
   - 实例化并注册额外的监听器

6. **FileEncodingApplicationListener**
   - 如果配置了 `spring.mandatory-file-encoding`，则校验与系统属性 `file.encoding` 是否一致
   - 不一致时抛出异常终止应用

#### contextPrepared

- ~~BackgroundPreinitializer~~（事件类型不匹配）
- ~~DelegatingApplicationListener~~（事件类型不匹配）

#### BootstrapContextClosed

无监听器响应此事件。

#### contextLoaded

> 将 SPI 加载的 ApplicationListener 注册到 ApplicationContext，并发布事件。

1. **EnvironmentPostProcessorApplicationListener**：无额外操作
2. **LoggingApplicationListener**：向容器注册 `LoggingSystem` 和 `LoggerGroup` 实例
3. ~~BackgroundPreinitializer~~（事件类型不匹配）
4. ~~DelegatingApplicationListener~~（配置为空时无操作）

#### started

- ~~BackgroundPreinitializer~~（事件类型不匹配）
- ~~DelegatingApplicationListener~~（配置为空时无操作）

### 事件发布机制

**支持的事件类型：**
`starting`、`environmentPrepared`、`contextPrepared`、`contextLoaded`、`started`、`running`、`failed`

```java
void starting(ConfigurableBootstrapContext bootstrapContext, Class<?> mainApplicationClass) {
    doWithListeners("spring.boot.application.starting", 
        listener -> listener.starting(bootstrapContext),
        step -> {
            if (mainApplicationClass != null) {
                step.tag("mainApplicationClass", mainApplicationClass.getName());
            }
        });
}
```

**发布流程：**

1. `SpringApplicationRunListeners` 调用事件方法
2. 遍历执行每个 `SpringApplicationRunListener` 的同名方法
3. 内部使用 `SimpleApplicationEventMulticaster` 向 [SPI 加载的监听器](#113-spring-boot-spi-加载机制)发布事件
4. 监听器匹配逻辑：
   - 实现 `GenericApplicationListener`：直接调用 `supportsEventType()` 和 `supportsSourceType()`
   - 否则通过适配器模式匹配事件类型

### Attach 解析

#### 1. SpringConfigurationPropertySources

将普通的 `PropertySource` 列表包装为 `ConfigurationPropertySource`：

```java
class SpringConfigurationPropertySources implements Iterable<ConfigurationPropertySource> {
    @Override
    public Iterator<ConfigurationPropertySource> iterator() {
        return new SourcesIterator(this.sources.iterator(), this::adapt);
    }
}

static SpringConfigurationPropertySource from(PropertySource<?> source) {
    PropertyMapper[] mappers = getPropertyMappers(source);
    if (isFullEnumerable(source)) {
        // 可枚举的 Map 类型 Source
        return new SpringIterableConfigurationPropertySource(
            (EnumerablePropertySource<?>) source, mappers);
    }
    // 普通 Source
    return new SpringConfigurationPropertySource(source, mappers);
}
```

#### 2. ConfigurationPropertySourcesPropertySource

重写 `getProperty()` 方法，支持从包装后的 Source 中查找配置：

```java
public Object getProperty(String name) {
    ConfigurationProperty property = findConfigurationProperty(name);
    return (property != null) ? property.getValue() : null;
}
```

**核心功能：**
- 将 `spring.application.name` 解析为 Elements 对象
- 支持 `-`、中括号等多种命名风格
- 最终包装为 `ConfigurationPropertyName` 进行匹配

### EnvironmentPostProcessor 解析

| 处理器 | 功能说明 |
|--------|----------|
| **RandomValuePropertySourceEnvironmentPostProcessor** | 添加 `random` PropertySource，支持 `random.int`、`random.uuid` 等随机值生成 |
| **SystemEnvironmentPropertySourceEnvironmentPostProcessor** | 将 `systemEnvironment` 替换为 `OriginAwareSystemEnvironmentPropertySource` |
| **SpringApplicationJsonEnvironmentPostProcessor** | 解析 `SPRING_APPLICATION_JSON` 或 `spring.application.json`，序列化为 Map 后作为 PropertySource |
| **CloudFoundryVcapEnvironmentPostProcessor** | Cloud Foundry 环境下添加 vcap PropertySource |
| **ConfigDataEnvironmentPostProcessor** | 注册 Binder，加载 `application.properties` 和 `application.yml` |
| **DebugAgentEnvironmentPostProcessor** | 存在 `reactor.tools.agent.ReactorDebugAgent` 时执行初始化 |

### Initializer 解析

| Initializer | 功能说明 |
|-------------|----------|
| **DelegatingApplicationContextInitializer** | 从 `context.initializer.classes` 加载额外的 Initializer |
| **SharedMetadataReaderFactoryContextInitializer** | 添加 `CachingMetadataReaderFactoryPostProcessor`，影响 Refresh 阶段的 `InvokeBeanFactoryPostProcessor` |
| **ContextIdApplicationContextInitializer** | 生成 ContextId 对象注册到容器，名称取自 `spring.application.name`（默认为 `application`） |
| **ConfigurationWarningsApplicationContextInitializer** | 添加 `ConfigurationWarningsPostProcessor`，影响 Refresh 阶段 |
| **RSocketPortInfoApplicationContextInitializer** | RSocket 启动时记录端口号到 `server.ports` |
| **ServerPortInfoApplicationContextInitializer** | WebServer 启动时记录端口号到 `server.ports` |
| **ConditionEvaluationReportLoggingListener** | 打印条件注解匹配报告 |
