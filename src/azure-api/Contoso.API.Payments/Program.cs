// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using Azure.Identity;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using System;
using System.Reflection;

var host = new HostBuilder()
    .ConfigureFunctionsWebApplication()
    .ConfigureAppConfiguration(configurationBuilder =>
    {
        configurationBuilder.AddUserSecrets(Assembly.GetExecutingAssembly(), optional: true);
        configurationBuilder.AddEnvironmentVariables();

        var keyVaultUri = Environment.GetEnvironmentVariable("AZURE_KEY_VAULT_ENDPOINT");
        if (keyVaultUri != null)
        {
            try
            {
                var keyVaultEndpoint = new Uri(keyVaultUri);
                configurationBuilder.AddAzureKeyVault(keyVaultEndpoint, new DefaultAzureCredential());
            }
            catch (Exception e)
            {
                Console.WriteLine($"Error configuring keyvault: {e.Message}");
            }
        }
    })
    .Build();

host.Run();